--[[
	EWRadioTests
	Phase 2 (AN/PRC-163) tests, appended to the Phase 1 suite by EWTestRunner.
	Radios are ordinary test-range stations with ElectronicType = "PRC163";
	traffic goes through RadioService:Transmit -> RF:EvaluateLink, the same path
	players use.

	Tests: R1 Registration (dual R/T) | R2 Programming validation | R3 Text traffic
	       R4 COMSEC / zeroize | R5 Power levels | R6 Jamming | R7 PTT keying
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("EWShared")
local RadioDefinitions = require(Shared.RadioDefinitions)
local Env = require(script.Parent.EWTestEnvironment)

local RADIO = RadioDefinitions.PRC163

local EWRadioTests = {}

local nextFakeUser = 0
local function fakePlayer(name: string)
	nextFakeUser += 1
	return { Name = name, UserId = -9000 - nextFakeUser, Character = nil, Team = nil, Neutral = true, DisplayName = name }
end

-- A PRC-163 station on the ground at (x, z), optionally owned by a fake player.
local function radio(context, env, settle, name: string, x: number, z: number, owner)
	if not env.Stations[name] then
		Env.CreateStation(env, name, env.Origin + Vector3.new(x, 0, z), { ElectronicType = "PRC163" })
	end
	Env.MoveStation(env, name, x, z)
	local model = env.Stations[name].Model
	if owner then
		model:SetAttribute("EWOwnerUserId", owner.UserId)
	end
	settle(context)
	local record = Env.GetRecord(env, name)
	if record then
		context.Registry:RefreshPose(record)
	end
	return record
end

local function knob(context, record, number: number)
	local state = context.Radio:GetState(record)
	local preset = RadioDefinitions.GetPreset(number)
	state.Knob = number
	state.ActiveRt = preset.Rt
	state.Rt[preset.Rt].Preset = nil
	-- Same path as the knob command, without needing an authorised player.
	local channel = state.Rt[preset.Rt]
	channel.Preset = preset.Number
	channel.RxMHz, channel.TxMHz = preset.RxMHz, preset.TxMHz
	channel.Comsec, channel.KeySlot = preset.Comsec, preset.KeySlot
	channel.Power, channel.Squelch, channel.Net = preset.Power, preset.Squelch, preset.Name
	context.Registry:Reconfigure(record)
end

local function deliveryTo(deliveries, record, rt: number)
	for _, d in ipairs(deliveries or {}) do
		if d.Record == record and d.Rt == rt then
			return d
		end
	end
	return nil
end

function EWRadioTests.Get(h)
	local newCheck, settle, describe = h.newCheck, h.settle, h.describe
	local Tests = {}

	table.insert(Tests, {
		Name = "R1 PRC-163 registration: two R/T channels on one device",
		Run = function(context, env, log)
			local check = newCheck(log)
			local record = radio(context, env, settle, "R_W", -700, -330)
			check.That(record ~= nil, "a PRC163 station registers")
			if not record then
				return check.Result()
			end
			check.That(record.DefinitionId == "PRC163", "ElectronicType PRC163 resolves to the radio definition")
			check.That(#record.Emitters == 2 and #record.Receivers == 2, "R/T 1 and R/T 2 each have an emitter and a receiver")
			local p1 = RadioDefinitions.GetPreset(RADIO.DefaultKnob)
			check.That(math.abs(record.Receivers[p1.Rt].FrequencyMHz - p1.RxMHz) < 1e-6, string.format("knob %02d tunes R/T %d to %.3f MHz", p1.Number, p1.Rt, p1.RxMHz))
			local rt2 = RadioDefinitions.PresetsFor(2)[1]
			check.That(math.abs(record.Receivers[2].FrequencyMHz - rt2.RxMHz) < 1e-6, string.format("R/T 2 starts on its first preset (%.1f MHz)", rt2.RxMHz))
			check.That(not record.Emitters[1].Transmitting and not record.Emitters[2].Transmitting, "radio is silent until keyed")
			check.That(record.Battery ~= nil and record.PowerState == "On", "radio has a battery and is on")
			check.That(record.Emitters[2].ProfileId == "MANET_DATA_LBAND" or record.Emitters[2].FrequencyMHz < 500, "R/T 2 band profile follows its frequency")
			return check.Result()
		end,
	})

	table.insert(Tests, {
		Name = "R2 Programming validation (bands, knob, presets, schema)",
		Run = function(context, env, log)
			local check = newCheck(log)
			local owner = fakePlayer("RadioOwner")
			local record = radio(context, env, settle, "R_W", -700, -330, owner)
			if not record then
				check.That(false, "radio registered")
				return check.Result()
			end
			local device = env.Stations.R_W.Model
			local radioService = context.Radio
			local function run(payload)
				return radioService:Execute(owner :: any, payload)
			end
			check.That(record.OwnerUserId == owner.UserId, "radio is owned by the test player")
			local ok, code = run({ Action = "Knob", Device = device, Value = "FP" })
			check.That(ok, "knob to FP (" .. tostring(code) .. ")")
			ok, code = run({ Action = "Frequency", Device = device, Rt = 1, Number = 100 })
			check.That(not ok and code == "OUT_OF_BAND", "100 MHz is refused on R/T 1 (" .. tostring(code) .. ")")
			ok, code = run({ Action = "Frequency", Device = device, Rt = 1, Number = 45.123456 })
			check.That(ok and math.abs(record.Receivers[1].FrequencyMHz - 45.12346) < 1e-6, string.format("45.123456 MHz is quantized to 10 Hz (%.5f)", record.Receivers[1].FrequencyMHz))
			ok, code = run({ Action = "Frequency", Device = device, Rt = 2, Number = 45 })
			check.That(not ok and code == "OUT_OF_BAND", "45 MHz is refused on R/T 2 (" .. tostring(code) .. ")")
			ok, code = run({ Action = "Knob", Device = device, Number = 2 })
			check.That(ok and record.Receivers[1].FrequencyMHz == 45, "knob 02 selects PLT-NET 45.000 MHz")
			ok, code = run({ Action = "Frequency", Device = device, Rt = 1, Number = 46 })
			check.That(not ok and code == "KNOB_NOT_FP", "front-panel tuning needs the knob on FP (" .. tostring(code) .. ")")
			ok, code = run({ Action = "Preset", Device = device, Rt = 1, Number = 9 })
			check.That(not ok and code == "NO_PRESET", "an R/T 2 preset cannot be loaded on R/T 1 (" .. tostring(code) .. ")")

			local other = fakePlayer("Schema")
			local function runOther(payload)
				return radioService:Execute(other :: any, payload)
			end
			ok, code = runOther("garbage")
			check.That(not ok and code == "PAYLOAD_NOT_TABLE", "non-table payload refused")
			ok, code = runOther({ Action = "Explode", Device = device })
			check.That(not ok and code == "BAD_ENUM_ACTION", "unknown action refused")
			ok, code = runOther({ Action = "Knob", Device = device, Number = 1, Range = 5 })
			check.That(not ok and code == "UNEXPECTED_FIELD", "extra field refused")
			ok, code = runOther({ Action = "Text", Device = device, Text = string.rep("x", RADIO.TextMaxLength + 1) })
			check.That(not ok and code == "STRING_TOO_LONG_TEXT", "over-long text refused")
			ok, code = runOther({ Action = "Knob", Device = device, Value = "OFF" })
			check.That(not ok, "another player cannot program a carried radio (" .. tostring(code) .. ")")
			ok, code = runOther({ Action = "Text", Device = device, Text = "hi" })
			check.That(not ok, "another player cannot transmit on it (" .. tostring(code) .. ")")
			ok, code = runOther({ Action = "Knob", Device = workspace.Terrain })
			check.That(not ok and code == "NOT_RADIO", "commands to non-radios refused")
			device:SetAttribute("EWOwnerUserId", nil)
			settle(context)
			return check.Result()
		end,
	})

	table.insert(Tests, {
		Name = "R3 Text traffic over the RF engine (open lane, ridge, off-frequency)",
		Run = function(context, env, log)
			local check = newCheck(log)
			local w = radio(context, env, settle, "R_W", -700, -330)
			local e = radio(context, env, settle, "R_E", 700, -330)
			local rw = radio(context, env, settle, "R_RW", -700, 270)
			local re = radio(context, env, settle, "R_RE", 700, 270)
			local off = radio(context, env, settle, "R_OFF", 650, -330)
			if not (w and e and rw and re and off) then
				check.That(false, "radios registered")
				return check.Result()
			end
			for _, r in ipairs({ w, e, rw, re }) do
				knob(context, r, 2) -- PLT-NET 45.000 MHz CT
			end
			knob(context, off, 3) -- CO-NET 52.250 MHz
			settle(context)
			local text = "CONTACT GRID 4377 3905 OVER"
			local deliveries = context.Radio:Transmit(w, 1, text, "ALPHA")
			local d = deliveryTo(deliveries, e, 1)
			check.That(d ~= nil and d.Text == text, "open lane 1400 studs: message arrives intact (" .. (if d then d.State else "none") .. ")")
			if d then
				log("    open lane  " .. describe(d.Result))
				check.That(d.Readability >= 4, string.format("radio check reads %d/%d", d.Readability, d.Strength))
			end
			check.That(deliveryTo(deliveries, off, 1) == nil and deliveryTo(deliveries, off, 2) == nil, "a radio on another frequency hears nothing")

			task.wait(1.2)
			deliveries = context.Radio:Transmit(rw, 1, text, "BRAVO")
			local blocked = deliveryTo(deliveries, re, 1)
			if blocked then
				log("    ridge      " .. describe(blocked.Result))
			end
			check.That(blocked == nil or blocked.Text ~= text, "behind the ridge the message is lost or garbled (" .. (if blocked then blocked.State .. ": " .. blocked.Text else "nothing") .. ")")
			context.Radio:GetState(re).Rt[1].Squelch = "OFF"
			task.wait(1.2)
			deliveries = context.Radio:Transmit(rw, 1, text, "BRAVO")
			local open = deliveryTo(deliveries, re, 1)
			check.That(open == nil or open.Text ~= text, "with squelch OFF the blocked receiver still gets nothing intelligible (" .. (if open then open.Text else "nothing") .. ")")
			context.Radio:GetState(re).Rt[1].Squelch = "NOI"
			return check.Result()
		end,
	})

	table.insert(Tests, {
		Name = "R4 COMSEC: keys, zeroize and LOAD",
		Run = function(context, env, log)
			local check = newCheck(log)
			local w = radio(context, env, settle, "R_W", -700, -330)
			local e = radio(context, env, settle, "R_E", 700, -330)
			if not (w and e) then
				check.That(false, "radios registered")
				return check.Result()
			end
			knob(context, w, 2)
			knob(context, e, 2)
			local text = "PHASE LINE BLUE"
			task.wait(1.2)
			local d = deliveryTo(context.Radio:Transmit(w, 1, text, "ALPHA"), e, 1)
			check.That(d ~= nil and d.Text == text and not d.Encrypted, "same key fill: CT traffic is readable")

			local eState = context.Radio:GetState(e)
			eState.Keys = {}
			eState.Zeroized = true
			context.Registry:Reconfigure(e)
			task.wait(1.2)
			d = deliveryTo(context.Radio:Transmit(w, 1, text, "ALPHA"), e, 1)
			check.That(d ~= nil and d.Encrypted and d.Text ~= text, "zeroized receiver hears encrypted traffic it cannot read (" .. (if d then d.Text else "nothing") .. ")")

			knob(context, w, 6)
			knob(context, e, 6) -- MEDEVAC is plain text
			task.wait(1.2)
			d = deliveryTo(context.Radio:Transmit(w, 1, text, "ALPHA"), e, 1)
			check.That(d ~= nil and d.Text == text, "plain-text (PT) traffic is still readable after zeroize")

			knob(context, w, 2)
			knob(context, e, 2)
			local _, code = context.Radio:Transmit(e, 1, text, "ECHO")
			check.That(code == "NO_KEY", "a zeroized radio cannot transmit on a CT preset (" .. tostring(code) .. ")")

			local owner = fakePlayer("Loader")
			env.Stations.R_E.Model:SetAttribute("EWOwnerUserId", owner.UserId)
			settle(context)
			local ok = context.Radio:Execute(owner :: any, { Action = "Knob", Device = env.Stations.R_E.Model, Value = "LOAD" })
			check.That(ok and not eState.Zeroized, "knob LOAD refills the key slots")
			context.Radio:Execute(owner :: any, { Action = "Knob", Device = env.Stations.R_E.Model, Number = 2 })
			task.wait(1.2)
			d = deliveryTo(context.Radio:Transmit(w, 1, text, "ALPHA"), e, 1)
			check.That(d ~= nil and d.Text == text and not d.Encrypted, "after LOAD the net is readable again")
			env.Stations.R_E.Model:SetAttribute("EWOwnerUserId", nil)
			settle(context)
			return check.Result()
		end,
	})

	table.insert(Tests, {
		Name = "R5 Transmit power LOW / HIGH (0.25 W vs 5 W)",
		Run = function(context, env, log)
			local check = newCheck(log)
			local w = radio(context, env, settle, "R_W", -700, -330)
			local e = radio(context, env, settle, "R_E", 700, -330)
			if not (w and e) then
				check.That(false, "radios registered")
				return check.Result()
			end
			knob(context, w, 2)
			knob(context, e, 2)
			local function margin()
				return context.RF:EvaluateLink(w, e, { EmitterIndex = 1, ReceiverIndex = 1, Force = true, Deterministic = true, RefreshPose = true, IncludeInterference = false })
			end
			local high = margin()
			context.Radio:GetState(w).Rt[1].Power = "LOW"
			context.Registry:Reconfigure(w)
			local low = margin()
			context.Radio:GetState(w).Rt[1].Power = "HIGH"
			context.Registry:Reconfigure(w)
			log("    HIGH  " .. describe(high))
			log("    LOW   " .. describe(low))
			local diff = high.SinrDb - low.SinrDb
			check.That(math.abs(diff - 13) < 0.5, string.format("LOW power costs 13 dB of link margin (%.1f dB)", diff))
			return check.Result()
		end,
	})

	table.insert(Tests, {
		Name = "R6 Jamming: a VHF barrage jammer next to the receiver breaks the net",
		Run = function(context, env, log)
			local check = newCheck(log)
			local w = radio(context, env, settle, "R_W", -700, -330)
			local e = radio(context, env, settle, "R_E", 700, -330)
			if not (w and e) then
				check.That(false, "radios registered")
				return check.Result()
			end
			knob(context, w, 2)
			knob(context, e, 2)
			local text = "REQUEST FIRE MISSION"
			task.wait(1.2)
			local before = deliveryTo(context.Radio:Transmit(w, 1, text, "ALPHA"), e, 1)
			Env.CreateStation(env, "R_JAM", env.Origin + Vector3.new(690, 0, -320), { ElectronicType = "Jammer", Profile = "JAMMER_BARRAGE_VHF" })
			Env.MoveStation(env, "R_JAM", 690, -320)
			settle(context)
			local jammer = Env.GetRecord(env, "R_JAM")
			if jammer then
				context.Power:SetPower(jammer, true, "Test")
				local deadline = os.clock() + 8
				repeat
					task.wait(0.25)
				until jammer.PowerState == "On" or os.clock() > deadline
				context.Registry:SetEmitterTransmitting(jammer, 1, true)
				context.Registry:RefreshPose(jammer)
			end
			task.wait(0.3)
			local after = deliveryTo(context.Radio:Transmit(w, 1, text, "ALPHA"), e, 1)
			if after then
				log("    jammed  " .. describe(after.Result))
			end
			check.That(before ~= nil and before.Text == text, "without the jammer the message arrives intact")
			check.That(after == nil or after.Text ~= text, "with the jammer radiating it is lost or garbled (" .. (if after then after.State else "nothing") .. ")")
			check.That(e.PowerState == "On", "the jammed radio stays powered")
			env.Stations.R_JAM.Model:Destroy()
			env.Stations.R_JAM = nil
			settle(context)
			return check.Result()
		end,
	})

	table.insert(Tests, {
		Name = "R7 PTT keying, carrier rule and stuck-key timeout",
		Run = function(context, env, log)
			local check = newCheck(log)
			local owner = fakePlayer("Keyer")
			local w = radio(context, env, settle, "R_W", -700, -330, owner)
			if not w then
				check.That(false, "radio registered")
				return check.Result()
			end
			local device = env.Stations.R_W.Model
			knob(context, w, 2)
			local ok, code = context.Radio:Execute(owner :: any, { Action = "PttDown", Device = device, Rt = 1 })
			check.That(ok and w.Emitters[1].Transmitting, "PTT down keys R/T 1 (" .. tostring(code) .. ")")
			local active = false
			for _, entry in ipairs(context.RF:GetActiveEmissions()) do
				if entry.Record == w and entry.Index == 1 then
					active = true
				end
			end
			check.That(active, "the keyed R/T is an active emission in the RF engine")
			check.That(not w.Emitters[2].Transmitting, "R/T 2 stays silent")
			context.Radio:Execute(owner :: any, { Action = "PttUp", Device = device, Rt = 1 })
			check.That(not w.Emitters[1].Transmitting, "PTT up unkeys")
			local previous = RADIO.TxTimeoutSeconds
			RADIO.TxTimeoutSeconds = 1
			context.Radio:Execute(owner :: any, { Action = "PttDown", Device = device, Rt = 1 })
			task.wait(1.5)
			RADIO.TxTimeoutSeconds = previous
			check.That(not w.Emitters[1].Transmitting, "a stuck PTT unkeys after the TX timeout")
			device:SetAttribute("EWOwnerUserId", nil)
			settle(context)
			return check.Result()
		end,
	})

	return Tests
end

return EWRadioTests
