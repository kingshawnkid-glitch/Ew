--[[
	EW (Interaction Menu module)
	EW-equipment options for the Interaction Menu: the jammer backpack and any
	other device carrying an EWDetectable BoolValue (radios, beacons, sensors).

	Everything here is a REQUEST. The server validates rate, schema, carrier /
	teammate / range authorization and replies with the authoritative state,
	which this module caches to drive the labels.

	POINT ACTIONS (attribute EWAction on an "EWInteract" Attachment)
	  Menu      opens the full device menu (default when a device has no points)
	  Power     toggles power directly
	  Emission  toggles radiating (jammers / beacons; radios use PTT)
	  Battery   opens battery options (swap / check)
	  Mode      opens the operating-mode list (e.g. BARRAGE VHF / BARRAGE UHF / SPOT)
	  Status    shows a status readout
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Shared = ReplicatedStorage:WaitForChild("EWShared")
local EWRemotes = require(Shared:WaitForChild("EWRemotes"))
local SharedUtilities = require(Shared:WaitForChild("SharedUtilities"))

local commandRemote = EWRemotes.Get("DeviceCommand") :: RemoteEvent?
local statusRemote = EWRemotes.Get("DeviceStatus") :: RemoteEvent?

local EW = {}

EW.Settings = {
	Distance = 10, -- display distance; the server enforces its own interaction range
	StatusRefreshSeconds = 2.5, -- while a device's menu is visible
}

-- Pure-Lua signal: BindableEvents would copy the device table and break identity.
EW.StatusChanged = SharedUtilities.Signal.new("EWMenuStatusChanged") -- fires (device)

local statuses: { [Instance]: any } = {} -- device.Flag -> last server payload
local lastQuery: { [Instance]: number } = {}
local pendingReadout: { [Instance]: boolean } = {}
local devices: { [Instance]: any } = {} -- flag -> device (attached by the controller)
local lastGlobalQuery = 0

local C = {
	On = "#7CFC00",
	Busy = "#FFD24A",
	Off = "#FF4B4B",
	Dim = "#A8A8A8",
	Hot = "#FF8A1F",
}

local function tag(text: string, color: string): string
	return string.format('<font color="%s">[%s]</font>', color, text)
end

local function notify(title: string, text: string)
	pcall(function()
		StarterGui:SetCore("SendNotification", { Title = title, Text = text, Duration = 5 })
	end)
end

local function send(action: string, device, extra: { [string]: any }?)
	if not commandRemote then
		return
	end
	local payload = { Action = action, Device = device.Flag }
	if extra then
		for k, v in pairs(extra) do
			payload[k] = v
		end
	end
	commandRemote:FireServer(payload)
end

local function readout(status): string
	local parts = { status.PowerState or "?" }
	if type(status.BatteryPercent) == "number" then
		table.insert(parts, string.format("BATT %d%%", status.BatteryPercent))
	end
	if status.ManualEmission then
		table.insert(parts, if status.Emitting then "RADIATING" else "SILENT")
	end
	if status.ModeLabel then
		table.insert(parts, status.ModeLabel)
	end
	if type(status.FrequencyMHz) == "number" then
		table.insert(parts, string.format("%.3f MHz", status.FrequencyMHz))
	end
	if type(status.SpareBatteries) == "number" then
		table.insert(parts, string.format("%d spare", status.SpareBatteries))
	end
	return table.concat(parts, "  |  ")
end

-- Server replies: match them to every tracked device inside the reported root.
if statusRemote then
	statusRemote.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or typeof(payload.Root) ~= "Instance" then
			return
		end
		for flag, device in pairs(devices) do
			if device.Root == payload.Root or flag:IsDescendantOf(payload.Root) then
				statuses[flag] = payload
				if pendingReadout[flag] then
					pendingReadout[flag] = nil
					notify(payload.DisplayName or "EW device", readout(payload))
				end
				EW.StatusChanged:Fire(device)
			end
		end
	end)
end

function EW:Attach(device)
	devices[device.Flag] = device
end

function EW:Detach(device)
	devices[device.Flag] = nil
	statuses[device.Flag] = nil
	lastQuery[device.Flag] = nil
	pendingReadout[device.Flag] = nil
end

function EW:GetStatus(device)
	return statuses[device.Flag]
end

-- Throttled status request (stays well inside the server's rate limit).
function EW:RequestStatus(device, force: boolean?)
	local now = os.clock()
	local last = lastQuery[device.Flag] or 0
	if not force and now - last < self.Settings.StatusRefreshSeconds then
		return
	end
	if now - lastGlobalQuery < 0.35 and not force then
		return
	end
	lastQuery[device.Flag] = now
	lastGlobalQuery = now
	send("QueryStatus", device)
end

local function powerTag(status): string
	if not status then
		return tag("--", C.Dim)
	end
	local s = status.PowerState
	if s == "On" then
		return tag("ON", C.On)
	elseif s == "Booting" then
		return tag("BOOTING", C.Busy)
	elseif s == "Depleted" then
		return tag("DEPLETED", C.Off)
	elseif s == "Fault" then
		return tag("FAULT", C.Off)
	end
	return tag("OFF", C.Off)
end

local function emissionTag(status): string
	if not status then
		return tag("--", C.Dim)
	end
	if status.Emitting then
		return tag("RADIATING", C.Hot)
	end
	return tag("SILENT", C.Dim)
end

local function batteryText(status): string
	if not status or type(status.BatteryPercent) ~= "number" then
		return "BATTERY"
	end
	local p = status.BatteryPercent
	local color = if p > 30 then C.On elseif p > 10 then C.Busy else C.Off
	return string.format('BATTERY <font color="%s">%d%%</font>', color, p)
end

-- Label for an interaction point (the main button).
function EW:PointLabel(action: string, device, custom: string?): string
	local status = statuses[device.Flag]
	if action == "Power" then
		return (custom or "POWER") .. "  " .. powerTag(status)
	elseif action == "Emission" then
		return (custom or "EMISSION") .. "  " .. emissionTag(status)
	elseif action == "Battery" then
		return custom or batteryText(status)
	elseif action == "Mode" then
		return (custom or "MODE") .. "  " .. (if status and status.ModeLabel then tag(status.ModeLabel, C.Busy) else "")
	elseif action == "Status" then
		return custom or "STATUS"
	end
	local name = custom or (status and status.DisplayName) or device.DisplayName
	return string.upper(name) .. "  " .. powerTag(status)
end

-- Dot colour for an interaction point.
function EW:PointColor(_action: string, device): Color3
	local status = statuses[device.Flag]
	if not status then
		return Color3.new(1, 1, 1)
	end
	if status.Emitting then
		return Color3.fromRGB(255, 138, 31)
	elseif status.PowerState == "On" then
		return Color3.fromRGB(124, 252, 0)
	elseif status.PowerState == "Booting" then
		return Color3.fromRGB(255, 210, 74)
	end
	return Color3.new(1, 1, 1)
end

local function modeEntries(device)
	local status = statuses[device.Flag]
	local out = {}
	for i, mode in ipairs(status and status.Modes or {}) do
		local current = status.ModeId == mode.Id
		table.insert(out, {
			Id = "Mode:" .. mode.Id,
			Order = i,
			Text = if current then mode.Label .. "  " .. tag("ACTIVE", C.On) else mode.Label,
			Run = function()
				send("SetMode", device, { Mode = mode.Id })
			end,
		})
	end
	if #out == 0 then
		table.insert(out, { Id = "Mode:none", Order = 1, Text = tag("NO MODES", C.Dim), Run = function() end })
	end
	return out
end

local function batteryEntries(device)
	local status = statuses[device.Flag]
	local spares = status and status.SpareBatteries
	return {
		{
			Id = "Battery:Swap",
			Order = 1,
			Text = string.format("SWAP BATTERY  %s", tag(if type(spares) == "number" then tostring(spares) .. " SPARE" else "--", C.Dim)),
			Run = function()
				send("SwapBattery", device)
			end,
		},
		{
			Id = "Battery:Check",
			Order = 2,
			Text = "CHECK CHARGE",
			Run = function()
				pendingReadout[device.Flag] = true
				send("QueryStatus", device)
			end,
		},
	}
end

-- Run a direct action (from a point or a menu entry).
function EW:Run(action: string, device)
	if action == "Power" then
		send("TogglePower", device)
	elseif action == "Emission" then
		send("ToggleEmission", device)
	elseif action == "Status" then
		pendingReadout[device.Flag] = true
		send("QueryStatus", device)
	end
end

-- True when a point action opens a list instead of acting directly.
function EW:OpensList(action: string): boolean
	return action == "Menu" or action == "Battery" or action == "Mode"
end

-- Entries for the first list opened by a point. Entries with Children open the
-- third column (the Interaction Menu's "Interacts" level).
function EW:Entries(action: string, device)
	if action == "Battery" then
		return batteryEntries(device)
	elseif action == "Mode" then
		return modeEntries(device)
	end
	local status = statuses[device.Flag]
	local entries = {
		{
			Id = "Power",
			Order = 1,
			Text = "POWER  " .. powerTag(status),
			Run = function()
				send("TogglePower", device)
			end,
		},
	}
	if status == nil or status.ManualEmission then
		table.insert(entries, {
			Id = "Emission",
			Order = 2,
			Text = "EMISSION  " .. emissionTag(status),
			Run = function()
				send("ToggleEmission", device)
			end,
		})
	end
	if status == nil or (status.Modes and #status.Modes > 0) then
		table.insert(entries, {
			Id = "Mode",
			Order = 3,
			Text = "MODE  " .. (if status and status.ModeLabel then tag(status.ModeLabel, C.Busy) else "") .. "  >",
			Children = function()
				return modeEntries(device)
			end,
		})
	end
	if status == nil or type(status.BatteryPercent) == "number" then
		table.insert(entries, {
			Id = "Battery",
			Order = 4,
			Text = batteryText(status) .. "  >",
			Children = function()
				return batteryEntries(device)
			end,
		})
	end
	table.insert(entries, {
		Id = "Status",
		Order = 5,
		Text = "STATUS",
		Run = function()
			pendingReadout[device.Flag] = true
			send("QueryStatus", device)
		end,
	})
	return entries
end

return EW
