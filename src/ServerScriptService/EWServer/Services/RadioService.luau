--[[
	RadioService
	Phase 2: AN/PRC-163 radio state, front-panel programming, PTT and text
	traffic over the shared RF engine.

	MODEL
	  * One state table per radio (kept by root and by EWSerial, so it survives
	    respawns): function knob, selected R/T, crossband flag, volume, COMSEC key
	    slots, and per R/T: preset, RX/TX frequency, power level, squelch, COMSEC.
	  * A registry configuration extender turns that state into TWO emitters and
	    TWO receivers (":TX1"/":RX1" = R/T 1, ":TX2"/":RX2" = R/T 2), so every
	    Phase 1 system (power draw, interference, detection) sees both channels.
	  * Security profiles are simulated: "PT", or "CT:<key id>" from the radio's
	    key slot. Zeroize empties the slots; LOAD refills them from the carrier's
	    team fill (a captured, un-zeroized radio keeps its original keys).

	TRAFFIC (text first; voice can reuse the same delivery decisions later)
	  Transmit(record, rt, text, fromName) keys the R/T for a short burst and
	  evaluates RF:EvaluateLink to every other powered PRC-163 receiver that is
	  tuned in band. Per receiver the outcome depends on the link Quality and on
	  squelch / COMSEC:
	    Clear, Good ........ text as sent
	    Degraded ........... characters lost with the link's PacketLoss
	    Broken ............. heavy loss, words missing
	    Unusable ........... "[UNREADABLE]" (only with squelch OFF)
	    NoSignal / off-band  nothing
	    wrong / missing key  "[ENCRYPTED TRAFFIC]" (you hear it, you cannot read it)
	    TON squelch ........ also requires the same net (preset)
	  Listeners are the radio's carrier, or players next to an uncarried radio.

	SECURITY
	  RadioCommand is rate limited and schema checked. Programming requires
	  EWSecurityService:CanControlDevice; PTT / Text additionally require that
	  the player carries the radio. Text is filtered with TextService before it
	  is delivered to anyone. A stuck PTT unkeys after TxTimeoutSeconds.
]]

local Players = game:GetService("Players")
local TextService = game:GetService("TextService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("EWShared")
local RadioDefinitions = require(Shared.RadioDefinitions)
local SignalProfiles = require(Shared.SignalProfiles)
local SharedUtilities = require(Shared.SharedUtilities)

local RadioService = {}

RadioService.TrafficDelivered = SharedUtilities.Signal.new("RadioTrafficDelivered") -- (txRecord, deliveries)

local RADIO = RadioDefinitions.PRC163
local SPEAKER_RANGE_STUDS = 8 -- players this close hear an uncarried radio

local context
local config
local registry
local power
local rf
local security
local stateRemote: RemoteEvent
local trafficRemote: RemoteEvent

local states = setmetatable({}, { __mode = "k" }) :: { [Instance]: any }
local serialStates: { [string]: any } = {}

RadioService.Schema = {
	Action = {
		Type = "string",
		Enum = { "Query", "Knob", "SelectRt", "Preset", "PresetStep", "Frequency", "Power", "Squelch", "Comsec", "Volume", "Crossband", "Zeroize", "PttDown", "PttUp", "Text" },
	},
	Device = { Type = "Instance" },
	Rt = { Type = "number", Optional = true, Min = 1, Max = 2 },
	Number = { Type = "number", Optional = true, Min = -10000, Max = 10000 },
	Value = { Type = "string", Optional = true, MaxLength = 8 },
	Text = { Type = "string", Optional = true, MaxLength = RADIO.TextMaxLength },
}

local MESSAGES = {
	NOT_POWERED = "Radio is off",
	OUT_OF_BAND = "Frequency outside the R/T bands",
	NO_PRESET = "Preset not programmed for this R/T",
	NO_KEY = "No COMSEC key - LOAD or use PT",
	KNOB_NOT_FP = "Set the knob to FP to enter frequencies",
	NOT_CARRIED = "You must carry the radio to transmit",
	EMPTY_TEXT = "Nothing to send",
	FILTER_FAILED = "Message could not be sent",
	ZEROIZED = "Zeroized - all keys erased",
	KEYS_LOADED = "Keys loaded",
	TX_TIMEOUT = "TX timeout",
	NOT_RADIO = "Not a PRC-163",
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local function isRadio(record): boolean
	return record ~= nil and record.DefinitionId == RADIO.Id
end

local function teamNameOf(userId: number?): string
	local player = if userId then Players:GetPlayerByUserId(userId) else nil
	if player and player.Team and not player.Neutral then
		return player.Team.Name
	end
	return "NEUTRAL"
end

local function fillKeys(state, teamName: string)
	state.Keys = {}
	for slot = 1, RADIO.KeySlots do
		state.Keys[slot] = string.format("FILL:%s:%d", teamName, slot)
	end
	state.Zeroized = false
end

local function applyPreset(state, rt: number, preset)
	local channel = state.Rt[rt]
	channel.Preset = preset.Number
	channel.RxMHz = preset.RxMHz
	channel.TxMHz = preset.TxMHz
	channel.Comsec = preset.Comsec
	channel.KeySlot = preset.KeySlot
	channel.Power = preset.Power
	channel.Squelch = preset.Squelch
	channel.Net = preset.Name
end

local function newState(record)
	local state = {
		Knob = RADIO.DefaultKnob,
		ActiveRt = 1,
		Crossband = false,
		Volume = 6,
		TxRt = nil :: number?,
		TxToken = 0,
		Keys = {},
		Zeroized = false,
		Rt = {},
	}
	for rt = 1, 2 do
		state.Rt[rt] = { Preset = nil, RxMHz = 0, TxMHz = 0, Comsec = "PT", KeySlot = 1, Power = "HIGH", Squelch = "NOI", Net = nil }
		local first = RadioDefinitions.PresetsFor(rt)[1]
		if first then
			applyPreset(state, rt, first)
		end
	end
	local knobPreset = RadioDefinitions.GetPreset(RADIO.DefaultKnob)
	if knobPreset then
		applyPreset(state, knobPreset.Rt, knobPreset)
		state.ActiveRt = knobPreset.Rt
	end
	fillKeys(state, teamNameOf(record.OwnerUserId))
	return state
end

local function getState(record)
	local state = states[record.Root]
	if state then
		return state
	end
	if record.Serial then
		state = serialStates[record.Serial]
	end
	if not state then
		state = newState(record)
	end
	states[record.Root] = state
	if record.Serial then
		serialStates[record.Serial] = state
	end
	return state
end

local function securityProfileOf(record, state, channel): string
	if channel.Comsec ~= "CT" then
		return "PT"
	end
	local key = state.Keys[channel.KeySlot]
	if key then
		return "CT:" .. key
	end
	-- Unique per radio so two zeroized radios never "match" each other.
	return "CT:NOKEY:" .. record.Id
end

--------------------------------------------------------------------------------
-- Emitters / receivers (registry configuration extender)
--------------------------------------------------------------------------------

local function bandOf(rt: number, channel)
	return RadioDefinitions.BandFor(rt, channel.TxMHz) or RadioDefinitions.BandFor(rt, channel.RxMHz) or RADIO.Channels[rt].Bands[1]
end

local function buildChannels(record)
	local state = getState(record)
	local emitters, receivers = {}, {}
	for rt = 1, 2 do
		local channel = state.Rt[rt]
		local band = bandOf(rt, channel)
		local profile = SignalProfiles.GetOrDefault(band.Profile)
		local levels = if band.Id == "LS" then RADIO.LBandPowerLevelsDbm else RADIO.PowerLevelsDbm
		local securityProfile = securityProfileOf(record, state, channel)
		local antenna = SignalProfiles.CopyAntenna(profile.Antenna)
		emitters[rt] = {
			Id = record.Id .. ":TX" .. rt,
			DeviceId = record.Id,
			ProfileId = profile.Id,
			SignalType = profile.SignalType,
			Modulation = profile.Modulation,
			Intentional = true,
			FrequencyMHz = channel.TxMHz,
			BandwidthKHz = profile.BandwidthKHz,
			TxPowerDbm = levels[channel.Power] or profile.TxPowerDbm,
			DutyCycle = profile.DutyCycle,
			Transmitting = state.TxRt == rt,
			ContinuousEmission = false,
			NetworkId = channel.Net,
			SecurityProfile = securityProfile,
			Priority = 1,
			Stability = profile.Stability,
			Antenna = antenna,
			SignatureReductionDb = 0,
		}
		receivers[rt] = {
			Id = record.Id .. ":RX" .. rt,
			DeviceId = record.Id,
			ProfileId = profile.Id,
			Modulation = profile.Modulation,
			FrequencyMHz = channel.RxMHz,
			BandwidthKHz = profile.BandwidthKHz,
			SensitivityDbm = profile.SensitivityDbm,
			NoiseFigureDb = profile.NoiseFigureDb,
			RequiredSinrDb = profile.RequiredSinrDb,
			InterferenceRejectionDb = profile.InterferenceRejectionDb,
			NetworkId = channel.Net,
			SecurityProfile = securityProfile,
			Antenna = antenna,
			Enabled = true,
		}
	end
	record.Emitters = emitters
	record.Receivers = receivers
	record.DetectionClass = "Communications"
end

--------------------------------------------------------------------------------
-- Display state
--------------------------------------------------------------------------------

function RadioService:GetState(record)
	if not isRadio(record) then
		return nil
	end
	return getState(record)
end

function RadioService:StatePayload(record, ok: boolean?, code: string?)
	local state = getState(record)
	local channels = {}
	for rt = 1, 2 do
		local channel = state.Rt[rt]
		local band = bandOf(rt, channel)
		local preset = if channel.Preset then RadioDefinitions.GetPreset(channel.Preset) else nil
		channels[rt] = {
			Label = RadioDefinitions.PresetLabel(preset),
			Preset = channel.Preset,
			RxMHz = channel.RxMHz,
			TxMHz = channel.TxMHz,
			Waveform = band.Label,
			Mod = band.Mod,
			Traffic = band.Traffic,
			Power = channel.Power,
			Squelch = channel.Squelch,
			Comsec = channel.Comsec,
			KeySlot = channel.KeySlot,
			KeyLoaded = channel.Comsec ~= "CT" or state.Keys[channel.KeySlot] ~= nil,
			Transmitting = state.TxRt == rt and record.PowerState == "On",
		}
	end
	local keysLoaded = 0
	for slot = 1, RADIO.KeySlots do
		if state.Keys[slot] then
			keysLoaded += 1
		end
	end
	return {
		Device = record.Root,
		Ok = ok ~= false,
		Message = code and (MESSAGES[code] or code) or nil,
		PowerState = record.PowerState,
		BatteryPercent = if record.Battery then math.floor(power:GetBatteryFraction(record) * 100 + 0.5) else nil,
		Knob = state.Knob,
		ActiveRt = state.ActiveRt,
		Crossband = state.Crossband,
		Volume = state.Volume,
		Zeroized = state.Zeroized,
		KeysLoaded = keysLoaded,
		Channels = channels,
	}
end

local function listenersOf(record): { Player }
	if record.OwnerUserId then
		local carrier = Players:GetPlayerByUserId(record.OwnerUserId)
		return if carrier then { carrier } else {}
	end
	local out = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") and (hrp.Position - record.Position).Magnitude <= SPEAKER_RANGE_STUDS then
			table.insert(out, player)
		end
	end
	return out
end

local function pushState(record, ok: boolean?, code: string?)
	if not stateRemote then
		return
	end
	local payload = RadioService:StatePayload(record, ok, code)
	for _, player in ipairs(listenersOf(record)) do
		stateRemote:FireClient(player, payload)
	end
end

local function reconfigure(record)
	registry:Reconfigure(record)
end

--------------------------------------------------------------------------------
-- Keying
--------------------------------------------------------------------------------

local function unkey(record, state)
	local rt = state.TxRt
	state.TxRt = nil
	state.TxToken += 1
	if rt then
		registry:SetEmitterTransmitting(record, rt, false)
	end
end

-- Keys one R/T for at most `seconds` (default: the stuck-PTT timeout).
local function key(record, state, rt: number, seconds: number?): (boolean, string?)
	if record.PowerState ~= "On" then
		return false, "NOT_POWERED"
	end
	local channel = state.Rt[rt]
	if channel.Comsec == "CT" and not state.Keys[channel.KeySlot] then
		return false, "NO_KEY"
	end
	if state.TxRt and state.TxRt ~= rt then
		registry:SetEmitterTransmitting(record, state.TxRt, false)
	end
	state.TxRt = rt
	state.TxToken += 1
	local token = state.TxToken
	registry:SetEmitterTransmitting(record, rt, true)
	local limit = math.min(seconds or RADIO.TxTimeoutSeconds, RADIO.TxTimeoutSeconds)
	local isPtt = seconds == nil
	task.delay(limit, function()
		if state.TxToken == token and state.TxRt == rt then
			unkey(record, state)
			-- A held PTT reaching the limit is a stuck key; a finished text burst is normal.
			pushState(record, not isPtt, if isPtt then "TX_TIMEOUT" else nil)
		end
	end)
	return true, nil
end

--------------------------------------------------------------------------------
-- Traffic
--------------------------------------------------------------------------------

local GARBLE = { ".", "-", "~", "#", "*" }

-- Drops characters with probability `loss` (spaces survive more often so the
-- message keeps its shape). Deterministic per message for reproducible tests.
local function garble(text: string, loss: number, rng: Random): string
	if loss <= 0.01 then
		return text
	end
	local out = table.create(#text)
	for _, code in utf8.codes(text) do
		local ch = utf8.char(code)
		local p = if ch == " " then loss * 0.3 else loss
		if rng:NextNumber() < p then
			table.insert(out, GARBLE[rng:NextInteger(1, #GARBLE)])
		else
			table.insert(out, ch)
		end
	end
	return table.concat(out)
end

local function receivesFrequency(receiver, emitter): boolean
	local halfSpanMHz = (math.max(receiver.BandwidthKHz, emitter.BandwidthKHz) / 2) / 1000
	return math.abs(receiver.FrequencyMHz - emitter.FrequencyMHz) <= halfSpanMHz
end

-- Decides what one receiving R/T presents for a transmission (nil = silence).
local function presentation(result, rxChannel, text: string, rng: Random): (string?, boolean)
	local compatibility = result.Compatibility
	local quality = result.Quality
	if not compatibility.InBand or not compatibility.ModulationMatch then
		return nil, false
	end
	local state = quality.State
	if state == "NoSignal" or state == "Offline" then
		return nil, false
	end
	if rxChannel.Squelch == "TON" and not compatibility.NetworkMatch then
		return nil, false -- tone squelch stays closed for other nets
	end
	if state == "Unusable" then
		return if rxChannel.Squelch == "OFF" then "[UNREADABLE]" else nil, false
	end
	if not compatibility.SecurityMatch then
		return "[ENCRYPTED TRAFFIC]", true
	end
	if state == "Clear" or state == "Good" then
		return text, false
	elseif state == "Degraded" then
		return garble(text, math.clamp(quality.PacketLoss, 0.08, 0.45), rng), false
	end
	return garble(text, math.clamp(quality.PacketLoss, 0.45, 0.8), rng), false
end

local function burstSeconds(text: string): number
	return math.clamp(0.6 + #text * 0.04, 0.8, 4)
end

--[[
	Transmit(txRecord, rt, text, fromName) -> deliveries
	text must already be filtered. Each delivery:
	  { Record, Rt, Text, State, Readability, Strength, Encrypted, Result }
	Fires RadioTraffic to every listener of each receiving radio.
]]
function RadioService:Transmit(txRecord, rt: number, text: string, fromName: string)
	local state = getState(txRecord)
	local ok, code = key(txRecord, state, rt, burstSeconds(text))
	if not ok then
		return nil, code
	end
	local emitter = txRecord.Emitters[rt]
	local deliveries = {}
	local rng = Random.new(txRecord.Revision * 7919 + #text)
	for _, rxRecord in ipairs(registry:GetDeviceList()) do
		if rxRecord ~= txRecord and isRadio(rxRecord) and rxRecord.PowerState == "On" and rxRecord.InWorld then
			local rxState = getState(rxRecord)
			for ri = 1, 2 do
				local receiver = rxRecord.Receivers[ri]
				if receiver and receivesFrequency(receiver, emitter) then
					local result = rf:EvaluateLink(txRecord, rxRecord, {
						EmitterIndex = rt,
						ReceiverIndex = ri,
						Force = true,
						RefreshPose = true,
						IncludeInterference = true,
						Priority = 1,
					})
					local shown, encrypted = presentation(result, rxState.Rt[ri], text, rng)
					if shown then
						local delivery = {
							Record = rxRecord,
							Rt = ri,
							Text = shown,
							State = result.Quality.State,
							Readability = result.Quality.Readability,
							Strength = result.Quality.Strength,
							Encrypted = encrypted,
							Result = result,
						}
						table.insert(deliveries, delivery)
						if trafficRemote then
							local channel = rxState.Rt[ri]
							local preset = if channel.Preset then RadioDefinitions.GetPreset(channel.Preset) else nil
							local payload = {
								Device = rxRecord.Root,
								Rt = ri,
								Label = RadioDefinitions.PresetLabel(preset),
								FrequencyMHz = receiver.FrequencyMHz,
								From = if encrypted then "?" else fromName,
								Text = shown,
								State = delivery.State,
								Readability = delivery.Readability,
								Strength = delivery.Strength,
								Encrypted = encrypted,
							}
							for _, player in ipairs(listenersOf(rxRecord)) do
								trafficRemote:FireClient(player, payload)
							end
						end
					end
				end
			end
		end
	end
	RadioService.TrafficDelivered:Fire(txRecord, deliveries)
	return deliveries, nil
end

local function filterText(text: string, fromUserId: number): string?
	local ok, result = pcall(function()
		local filtered = TextService:FilterStringAsync(text, fromUserId, Enum.TextFilterContext.PublicChat)
		return filtered:GetNonChatStringForBroadcastAsync()
	end)
	if ok and type(result) == "string" then
		return result
	end
	return nil
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function setKnob(record, state, payload): (boolean, string?)
	local value = payload.Value
	local number = payload.Number
	local wasOff = state.Knob == "OFF"
	if value == "OFF" then
		unkey(record, state)
		state.Knob = "OFF"
		power:SetPower(record, false, "Knob")
		return true, nil
	elseif value == "Z" then
		unkey(record, state)
		state.Knob = "Z"
		state.Keys = {}
		state.Zeroized = true
		reconfigure(record)
		return true, "ZEROIZED"
	elseif value == "LOAD" then
		state.Knob = "LOAD"
		fillKeys(state, teamNameOf(record.OwnerUserId))
		reconfigure(record)
		return true, "KEYS_LOADED"
	elseif value == "FP" then
		state.Knob = "FP"
	elseif value == nil and type(number) == "number" and number >= 1 and number <= RADIO.KnobPresets and number % 1 == 0 then
		local preset = RadioDefinitions.GetPreset(number)
		if not preset then
			return false, "NO_PRESET"
		end
		state.Knob = number
		applyPreset(state, preset.Rt, preset)
		state.ActiveRt = preset.Rt
		unkey(record, state)
		reconfigure(record)
	else
		return false, "BAD_KNOB"
	end
	if wasOff then
		power:SetPower(record, true, "Knob")
	end
	return true, nil
end

local function stepPreset(state, rt: number, direction: number): boolean
	local list = RadioDefinitions.PresetsFor(rt)
	if #list == 0 then
		return false
	end
	local current = state.Rt[rt].Preset
	local index = 0
	for i, preset in ipairs(list) do
		if preset.Number == current then
			index = i
		end
	end
	index = ((index - 1 + direction) % #list) + 1
	applyPreset(state, rt, list[index])
	return true
end

local function cycle(list: { string }, current: string): string
	local index = table.find(list, current) or 0
	return list[(index % #list) + 1]
end

--[[
	Execute(player, payload) -> (ok, code, record)
	Shared by the remote handler and the test runner. Performs ALL validation.
]]
function RadioService:Execute(player: Player, payload: any)
	if not security:CheckRate(player, "RadioCommand") then
		security:Reject(player, "RadioCommand", "RATE_LIMIT")
		return false, "RATE_LIMIT", nil
	end
	local valid, why = security:ValidatePayload(payload, RadioService.Schema)
	if not valid then
		security:Reject(player, "RadioCommand", why or "INVALID")
		return false, why or "INVALID", nil
	end
	local record = registry:FindDeviceFromInstance(payload.Device)
	if not isRadio(record) then
		security:Reject(player, "RadioCommand", "NOT_RADIO")
		return false, "NOT_RADIO", nil
	end
	local allowed, reason = security:CanControlDevice(player, record)
	if not allowed then
		security:Reject(player, "RadioCommand", reason or "DENIED")
		return false, reason or "DENIED", record
	end
	local state = getState(record)
	local action = payload.Action
	local rt = if payload.Rt then math.floor(payload.Rt) else state.ActiveRt
	if rt ~= 1 and rt ~= 2 then
		return false, "BAD_RT", record
	end
	local channel = state.Rt[rt]

	if action == "Query" then
		return true, nil, record
	elseif action == "Knob" then
		local ok, code = setKnob(record, state, payload)
		return ok, code, record
	elseif action == "SelectRt" then
		state.ActiveRt = rt
		return true, nil, record
	elseif action == "Preset" then
		local preset = if payload.Number then RadioDefinitions.GetPreset(math.floor(payload.Number)) else nil
		if not preset or preset.Rt ~= rt then
			return false, "NO_PRESET", record
		end
		applyPreset(state, rt, preset)
		reconfigure(record)
		return true, nil, record
	elseif action == "PresetStep" then
		local direction = if payload.Number and payload.Number < 0 then -1 else 1
		if not stepPreset(state, rt, direction) then
			return false, "NO_PRESET", record
		end
		reconfigure(record)
		return true, nil, record
	elseif action == "Frequency" then
		if state.Knob ~= "FP" then
			return false, "KNOB_NOT_FP", record
		end
		local mhz = payload.Number
		if type(mhz) ~= "number" then
			return false, "MISSING_NUMBER", record
		end
		mhz = RadioDefinitions.QuantizeMHz(mhz)
		if not RadioDefinitions.BandFor(rt, mhz) then
			return false, "OUT_OF_BAND", record
		end
		channel.Preset = nil
		channel.Net = nil -- front-panel channel: no net identity (TON squelch will not open)
		channel.RxMHz = mhz
		channel.TxMHz = mhz
		reconfigure(record)
		return true, nil, record
	elseif action == "Power" then
		channel.Power = if payload.Value and table.find(RADIO.PowerLevels, payload.Value) then payload.Value else cycle(RADIO.PowerLevels, channel.Power)
		reconfigure(record)
		return true, nil, record
	elseif action == "Squelch" then
		channel.Squelch = if payload.Value and table.find(RADIO.SquelchModes, payload.Value) then payload.Value else cycle(RADIO.SquelchModes, channel.Squelch)
		return true, nil, record
	elseif action == "Comsec" then
		channel.Comsec = if payload.Value == "PT" or payload.Value == "CT" then payload.Value elseif channel.Comsec == "CT" then "PT" else "CT"
		reconfigure(record)
		return true, nil, record
	elseif action == "Volume" then
		local delta = if payload.Number then math.clamp(math.floor(payload.Number), -RADIO.VolumeMax, RADIO.VolumeMax) else 1
		state.Volume = math.clamp(state.Volume + delta, 0, RADIO.VolumeMax)
		return true, nil, record
	elseif action == "Crossband" then
		state.Crossband = not state.Crossband
		return true, nil, record
	elseif action == "Zeroize" then
		-- Keypad ZERO: erase every key slot without moving the function knob.
		unkey(record, state)
		state.Keys = {}
		state.Zeroized = true
		reconfigure(record)
		return true, "ZEROIZED", record
	elseif action == "PttDown" or action == "PttUp" or action == "Text" then
		if record.OwnerUserId ~= player.UserId then
			security:Reject(player, "RadioCommand", "NOT_CARRIED")
			return false, "NOT_CARRIED", record
		end
		if action == "PttUp" then
			if state.TxRt == rt then
				unkey(record, state)
			end
			return true, nil, record
		elseif action == "PttDown" then
			local ok, code = key(record, state, rt, nil)
			return ok, code, record
		end
		local text = payload.Text
		if type(text) ~= "string" or string.match(text, "^%s*$") then
			return false, "EMPTY_TEXT", record
		end
		if not security:CheckRate(player, "RadioText") then
			security:Reject(player, "RadioCommand", "TEXT_RATE_LIMIT")
			return false, "RATE_LIMIT", record
		end
		local filtered = filterText(text, player.UserId)
		if not filtered then
			return false, "FILTER_FAILED", record
		end
		local deliveries, code = self:Transmit(record, rt, filtered, player.DisplayName)
		if not deliveries then
			return false, code, record
		end
		if trafficRemote then
			trafficRemote:FireClient(player, {
				Device = record.Root,
				Rt = rt,
				Label = RadioDefinitions.PresetLabel(if channel.Preset then RadioDefinitions.GetPreset(channel.Preset) else nil),
				FrequencyMHz = channel.TxMHz,
				From = player.DisplayName,
				Text = filtered,
				Sent = true,
			})
		end
		return true, nil, record
	end
	return false, "UNKNOWN_ACTION", record
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function RadioService:Init(ctx)
	context = ctx
	config = ctx.Config
	registry = ctx.Registry
	power = ctx.Power
	rf = ctx.RF
	security = ctx.Security
end

function RadioService:Start()
	stateRemote = context.Remotes.RadioState :: RemoteEvent
	trafficRemote = context.Remotes.RadioTraffic :: RemoteEvent
	local commandRemote = context.Remotes.RadioCommand :: RemoteEvent

	registry:AddConfigurationExtender(function(record, _attrs, definition)
		if definition.Id == RADIO.Id then
			buildChannels(record)
		end
	end)

	commandRemote.OnServerEvent:Connect(function(player: Player, payload: any)
		local ok, code, record = self:Execute(player, payload)
		if code == "RATE_LIMIT" or not record then
			return -- malformed or flooding: no reply
		end
		if record.OwnerUserId == player.UserId or not record.OwnerUserId then
			stateRemote:FireClient(player, self:StatePayload(record, ok, code))
		end
		if record.OwnerUserId and record.OwnerUserId ~= player.UserId then
			pushState(record, ok, code) -- a teammate changed the carrier's radio
		end
	end)

	power.PowerStateChanged:Connect(function(record, _, newState)
		if not isRadio(record) then
			return
		end
		local state = getState(record)
		if newState ~= "On" then
			unkey(record, state)
		end
		-- Powered on from elsewhere (EW menu) while the knob reads OFF.
		if (newState == "On" or newState == "Booting") and state.Knob == "OFF" then
			state.Knob = "FP"
		end
		pushState(record, true, nil)
	end)
	registry.DeviceChanged:Connect(function(record, kind)
		if kind == "Owner" and isRadio(record) then
			pushState(record, true, nil)
		end
	end)
	registry.DeviceUnregistered:Connect(function(record)
		local state = states[record.Root]
		if state then
			unkey(record, state)
		end
	end)
end

return RadioService
