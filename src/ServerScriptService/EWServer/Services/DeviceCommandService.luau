--[[
	DeviceCommandService
	Handles the DeviceCommand RemoteEvent (power control and status queries)
	used by the Interaction Menu module and later equipment UIs.

	Request : { Action = "TogglePower" | "SetPower" | "QueryStatus", Device = Instance, On = boolean? }
	Reply   : DeviceStatus RemoteEvent to the requesting player only
	          { Ok, DisplayName, PowerState, BatteryPercent?, Message? }

	Battery warnings are pushed to the carrier of the device (if any).
]]

local Players = game:GetService("Players")

local DeviceCommandService = {}

local context
local registry
local power
local security
local statusRemote: RemoteEvent

local SCHEMA = {
	Action = { Type = "string", Enum = { "TogglePower", "SetPower", "QueryStatus" } },
	Device = { Type = "Instance" },
	On = { Type = "boolean", Optional = true },
}

local MESSAGES = {
	POWERING_ON = "Powering on",
	POWERED_OFF = "Powered off",
	ALREADY_ON = "Already on",
	ALREADY_OFF = "Already off",
	DEVICE_FAULT = "Device fault",
	BATTERY_DEPLETED = "Battery depleted",
	NOT_OWNER = "Not your equipment",
	OUT_OF_RANGE = "Too far away",
	NO_CHARACTER = "No character",
	WRONG_FACTION = "Access denied",
	UNKNOWN_DEVICE = "Not an electronic device",
}

local function statusPayload(record, ok: boolean, message: string?)
	return {
		Ok = ok,
		DisplayName = record and record.DisplayName or "Unknown",
		PowerState = record and record.PowerState or "Unknown",
		BatteryPercent = if record and record.Battery then math.floor(power:GetBatteryFraction(record) * 100 + 0.5) else nil,
		Message = message,
	}
end

local function reply(player: Player, record, ok: boolean, code: string?)
	statusRemote:FireClient(player, statusPayload(record, ok, code and (MESSAGES[code] or code) or nil))
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
		if not security:CheckRate(player, "DeviceCommand") then
			security:Reject(player, "DeviceCommand", "RATE_LIMIT")
			return
		end
		local valid, why = security:ValidatePayload(payload, SCHEMA)
		if not valid then
			security:Reject(player, "DeviceCommand", why or "INVALID")
			return
		end
		local record = registry:FindDeviceFromInstance(payload.Device)
		if not record then
			security:Reject(player, "DeviceCommand", "UNKNOWN_DEVICE")
			reply(player, nil, false, "UNKNOWN_DEVICE")
			return
		end
		local allowed, reason = security:CanControlDevice(player, record)
		if not allowed then
			security:Reject(player, "DeviceCommand", reason or "DENIED")
			reply(player, record, false, reason)
			return
		end
		if payload.Action == "QueryStatus" then
			reply(player, record, true, nil)
		elseif payload.Action == "TogglePower" then
			local on = not (record.PowerState == "On" or record.PowerState == "Booting")
			local ok, code = power:SetPower(record, on, "Player")
			reply(player, record, ok, code)
		elseif payload.Action == "SetPower" then
			if payload.On == nil then
				security:Reject(player, "DeviceCommand", "MISSING_ON")
				return
			end
			local ok, code = power:SetPower(record, payload.On, "Player")
			reply(player, record, ok, code)
		end
	end)

	power.BatteryWarning:Connect(function(record, level, fraction)
		if record.OwnerUserId then
			local player = Players:GetPlayerByUserId(record.OwnerUserId)
			if player then
				statusRemote:FireClient(player, statusPayload(record, true, string.format("BATTERY %s (%d%%)", string.upper(level), math.floor(fraction * 100 + 0.5))))
			end
		end
	end)
	power.PowerStateChanged:Connect(function(record, _, newState, reason)
		if newState == "Depleted" and record.OwnerUserId then
			local player = Players:GetPlayerByUserId(record.OwnerUserId)
			if player then
				statusRemote:FireClient(player, statusPayload(record, false, "BATTERY DEPLETED - SHUTDOWN"))
			end
		elseif reason == "BootComplete" and record.OwnerUserId then
			local player = Players:GetPlayerByUserId(record.OwnerUserId)
			if player then
				statusRemote:FireClient(player, statusPayload(record, true, "Ready"))
			end
		end
	end)
end

return DeviceCommandService
