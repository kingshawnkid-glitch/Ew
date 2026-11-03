--[[
	EWClientController (LocalScript)
	Client entry point for the EW system. The client is presentation only:
	it renders what the server reports and sends validated REQUESTS.

	Phase 1 responsibilities
	  * DeviceStatus notifications (power, battery warnings, command replies)
	  * Loads the developer diagnostics panel only when the server marks this
	    player with the "EWDeveloper" attribute (the server re-checks every
	    diagnostics request, so the attribute grants nothing by itself)
	  * Exposes EWClient.Modules.EWClientAPI for other client code
]]

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")

local player = Players.LocalPlayer
local modules = script.Parent:WaitForChild("Modules")
local ClientAPI = require(modules:WaitForChild("EWClientAPI"))

local function notify(title: string, text: string)
	-- SetCore can fail while the CoreScripts are still loading; retry briefly.
	task.spawn(function()
		for _ = 1, 10 do
			local ok = pcall(function()
				StarterGui:SetCore("SendNotification", { Title = title, Text = text, Duration = 4 })
			end)
			if ok then
				return
			end
			task.wait(0.5)
		end
	end)
end

ClientAPI.StatusReceived:Connect(function(payload)
	if type(payload) ~= "table" or payload.Quiet then
		return -- quiet replies feed UIs (e.g. menu labels) without a notification
	end
	local lines = { tostring(payload.PowerState or "?") }
	if type(payload.BatteryPercent) == "number" then
		table.insert(lines, string.format("BATT %d%%", payload.BatteryPercent))
	end
	if type(payload.Message) == "string" then
		table.insert(lines, payload.Message)
	end
	notify(tostring(payload.DisplayName or "Device"), table.concat(lines, "  |  "))
end)

local diagnosticsLoaded = false
local function maybeLoadDiagnostics()
	if diagnosticsLoaded or player:GetAttribute("EWDeveloper") ~= true then
		return
	end
	diagnosticsLoaded = true
	local ui = require(modules:WaitForChild("EWDiagnosticsUI"))
	ui.Start()
end

player:GetAttributeChangedSignal("EWDeveloper"):Connect(maybeLoadDiagnostics)
maybeLoadDiagnostics()
