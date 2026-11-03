--[[
	DeviceCommandService
	Handles the DeviceCommand RemoteEvent used by the EW Interaction Menu and
	later equipment UIs. Every request is validated by EWSecurityService
	(rate limit, schema, carrier/teammate/range authorization).

	Request : {
	    Action = "TogglePower" | "SetPower" | "QueryStatus" | "ToggleEmission" | "SetMode" | "SwapBattery",
	    Device = Instance,      -- any instance inside the device (the menu sends the EWDetectable BoolValue)
	    On     = boolean?,      -- SetPower
	    Mode   = string?,       -- SetMode: a mode Id from the device definition (e.g. "BARRAGE_VHF")
	}
	Reply   : DeviceStatus RemoteEvent to the requesting player only, see statusPayload().

	Rules
	  * ToggleEmission only for definitions with ManualEmission (jammers, beacons);
	    radios key through PTT (Phase 2). Requires the device to be On.
	  * SetMode only accepts modes listed in the device definition. Barrage modes
	    use the profile's band centre; SPOT restores the EWSpotChannel attribute.
	  * SwapBattery consumes one of the REQUESTING player's spare batteries and
	    interrupts power (the device must be switched back on).
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("EWShared")
local DeviceDefinitions = require(Shared.DeviceDefinitions)
local SignalProfiles = require(Shared.SignalProfiles)

local DeviceCommandService = {}

local context
local registry
local power
local security
local statusRemote: RemoteEvent

DeviceCommandService.Schema = {
	Action = { Type = "string", Enum = { "TogglePower", "SetPower", "QueryStatus", "ToggleEmission", "SetMode", "SwapBattery" } },
	Device = { Type = "Instance" },
	On = { Type = "boolean", Optional = true },
	Mode = { Type = "string", Optional = true, MaxLength = 32 },
}

local MESSAGES = {
	POWERING_ON = "Powering on",
	POWERED_OFF = "Powered off",
	ALREADY_ON = "Already on",
	ALREADY_OFF = "Already off",
	DEVICE_FAULT = "Device fault",
	BATTERY_DEPLETED = "Battery depleted",
	BATTERY_REPLACED = "Battery replaced - power on to resume",
	NO_SPARE_BATTERY = "No spare battery",
	NO_BATTERY = "No battery",
	BATTERY_NOT_REMOVABLE = "Battery not removable",
	EMISSION_ON = "Radiating",
	EMISSION_OFF = "Emission off",
	NOT_POWERED = "Device is not powered",
	USE_PTT = "Radios transmit with PTT",
	NO_EMITTER = "No transmitter",
	UNKNOWN_MODE = "Mode not supported",
	MODE_SET = "Mode set",
	NOT_OWNER = "Not your equipment",
	OUT_OF_RANGE = "Too far away",
	NO_CHARACTER = "No character",
	WRONG_FACTION = "Access denied",
	UNKNOWN_DEVICE = "Not an electronic device",
}

local function definitionOf(record)
	return DeviceDefinitions.Get(record.DefinitionId) or DeviceDefinitions.Resolve(record.ElectronicType)
end

local function currentMode(record, definition)
	local emitter = record.Emitters[1]
	if not (definition.Modes and emitter) then
		return nil
	end
	for _, mode in ipairs(definition.Modes) do
		if mode.Profile == emitter.ProfileId then
			return mode
		end
	end
	return nil
end

function DeviceCommandService:StatusPayload(player: Player?, record, ok: boolean, code: string?, quiet: boolean?)
	local definition = record and definitionOf(record) or nil
	local emitter = record and record.Emitters[1] or nil
	local modes = nil
	if definition and definition.Modes then
		modes = {}
		for _, m in ipairs(definition.Modes) do
			table.insert(modes, { Id = m.Id, Label = m.Label })
		end
	end
	local mode = record and definition and currentMode(record, definition) or nil
	return {
		Ok = ok,
		Quiet = quiet == true,
		Root = record and record.Root or nil,
		DisplayName = record and record.DisplayName or "Unknown",
		ElectronicType = record and record.ElectronicType or nil,
		PowerState = record and record.PowerState or "Unknown",
		BatteryPercent = if record and record.Battery then math.floor(power:GetBatteryFraction(record) * 100 + 0.5) else nil,
		Emitting = emitter ~= nil and emitter.Transmitting and record.PowerState == "On",
		ManualEmission = definition ~= nil and definition.ManualEmission == true,
		FrequencyMHz = emitter and emitter.FrequencyMHz or nil,
		ModeId = mode and mode.Id or nil,
		ModeLabel = mode and mode.Label or nil,
		Modes = modes,
		SpareBatteries = if player then power:GetSpareBatteries(player) else nil,
		Message = code and (MESSAGES[code] or code) or nil,
	}
end

local function reply(player: Player, record, ok: boolean, code: string?, quiet: boolean?)
	statusRemote:FireClient(player, DeviceCommandService:StatusPayload(player, record, ok, code, quiet))
end

local function setMode(record, modeId: string): (boolean, string)
	local definition = definitionOf(record)
	local chosen = nil
	for _, mode in ipairs(definition.Modes or {}) do
		if mode.Id == modeId then
			chosen = mode
			break
		end
	end
	if not chosen then
		return false, "UNKNOWN_MODE"
	end
	local profile = SignalProfiles.Get(chosen.Profile)
	if not profile then
		return false, "UNKNOWN_MODE"
	end
	local root = record.Root
	local emitter = record.Emitters[1]
	-- Remember a spot tuning before leaving SPOT so it can be restored later.
	if emitter and emitter.ProfileId == "JAMMER_SPOT" then
		root:SetAttribute("EWSpotChannel", emitter.FrequencyMHz)
	end
	root:SetAttribute("SignalProfile", chosen.Profile)
	if profile.BandwidthKHz >= 1000 then
		root:SetAttribute("TransmissionChannel", profile.DefaultFrequencyMHz)
	else
		local spot = root:GetAttribute("EWSpotChannel")
		root:SetAttribute("TransmissionChannel", if type(spot) == "number" then spot else profile.DefaultFrequencyMHz)
	end
	-- Attribute signals are deferred; reconfigure now so the reply carries the new mode.
	registry:Reconfigure(record)
	return true, "MODE_SET"
end

local function toggleEmission(record): (boolean, string)
	local definition = definitionOf(record)
	if not definition.ManualEmission then
		return false, if record.ElectronicType == "Communications" then "USE_PTT" else "NO_EMITTER"
	end
	local emitter = record.Emitters[1]
	if not emitter then
		return false, "NO_EMITTER"
	end
	if record.PowerState ~= "On" then
		return false, "NOT_POWERED"
	end
	local on = not emitter.Transmitting
	registry:SetEmitterTransmitting(record, 1, on)
	-- Keep a designer-set attribute consistent so a later reconfiguration agrees.
	if record.Root:GetAttribute("EmissionEnabled") ~= nil then
		record.Root:SetAttribute("EmissionEnabled", on)
	end
	return true, if on then "EMISSION_ON" else "EMISSION_OFF"
end

--[[
	Execute(player, payload) -> (ok, code, record?)
	Shared by the remote handler and the test runner. Performs ALL validation.
]]
function DeviceCommandService:Execute(player: Player, payload: any)
	if not security:CheckRate(player, "DeviceCommand") then
		security:Reject(player, "DeviceCommand", "RATE_LIMIT")
		return false, "RATE_LIMIT", nil
	end
	local valid, why = security:ValidatePayload(payload, DeviceCommandService.Schema)
	if not valid then
		security:Reject(player, "DeviceCommand", why or "INVALID")
		return false, why or "INVALID", nil
	end
	local record = registry:FindDeviceFromInstance(payload.Device)
	if not record then
		security:Reject(player, "DeviceCommand", "UNKNOWN_DEVICE")
		return false, "UNKNOWN_DEVICE", nil
	end
	local allowed, reason = security:CanControlDevice(player, record)
	if not allowed then
		security:Reject(player, "DeviceCommand", reason or "DENIED")
		return false, reason or "DENIED", record
	end
	local action = payload.Action
	if action == "QueryStatus" then
		return true, nil, record
	elseif action == "TogglePower" then
		local on = not (record.PowerState == "On" or record.PowerState == "Booting")
		local ok, code = power:SetPower(record, on, "Player")
		return ok, code, record
	elseif action == "SetPower" then
		if payload.On == nil then
			security:Reject(player, "DeviceCommand", "MISSING_ON")
			return false, "MISSING_ON", record
		end
		local ok, code = power:SetPower(record, payload.On, "Player")
		return ok, code, record
	elseif action == "ToggleEmission" then
		local ok, code = toggleEmission(record)
		return ok, code, record
	elseif action == "SetMode" then
		if not payload.Mode then
			security:Reject(player, "DeviceCommand", "MISSING_MODE")
			return false, "MISSING_MODE", record
		end
		local ok, code = setMode(record, payload.Mode)
		return ok, code, record
	elseif action == "SwapBattery" then
		local ok, code = power:SwapBatteryFromPlayer(player, record)
		return ok, code, record
	end
	return false, "UNKNOWN_ACTION", record
end

function DeviceCommandService:Init(ctx)
	context = ctx
	registry = ctx.Registry
	power = ctx.Power
	security = ctx.Security
end

function DeviceCommandService:Start()
	statusRemote = context.Remotes.DeviceStatus :: RemoteEvent
	local commandRemote = context.Remotes.DeviceCommand :: RemoteEvent

	commandRemote.OnServerEvent:Connect(function(player: Player, payload: any)
		local ok, code, record = self:Execute(player, payload)
		if code == "RATE_LIMIT" or (not record and code ~= "UNKNOWN_DEVICE") then
			return -- malformed or flooding: no reply
		end
		local quiet = type(payload) == "table" and payload.Action == "QueryStatus" and ok
		reply(player, record, ok, code, quiet)
	end)

	local function notifyCarrier(record, ok: boolean, message: string)
		if record.OwnerUserId then
			local player = Players:GetPlayerByUserId(record.OwnerUserId)
			if player then
				local payload = self:StatusPayload(player, record, ok, nil, false)
				payload.Message = message
				statusRemote:FireClient(player, payload)
			end
		end
	end
	power.BatteryWarning:Connect(function(record, level, fraction)
		notifyCarrier(record, true, string.format("BATTERY %s (%d%%)", string.upper(level), math.floor(fraction * 100 + 0.5)))
	end)
	power.PowerStateChanged:Connect(function(record, _, newState, reason)
		if newState == "Depleted" then
			notifyCarrier(record, false, "BATTERY DEPLETED - SHUTDOWN")
		elseif reason == "BootComplete" then
			notifyCarrier(record, true, "Ready")
		end
	end)
end

return DeviceCommandService
