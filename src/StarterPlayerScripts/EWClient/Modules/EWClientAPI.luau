--[[
	EWClientAPI
	Thin client wrapper around the EW remotes. Other client code (equipment UIs,
	the Interaction Menu module) can use it instead of touching remotes directly.

	    local API = require(StarterPlayerScripts.EWClient.Modules.EWClientAPI)
	    API.TogglePower(someInstanceInsideTheDevice)
	    API.StatusReceived:Connect(function(status) ... end)

	All calls are requests; the server validates ownership, range and rate.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("EWShared")
local EWRemotes = require(Shared.EWRemotes)
local SharedUtilities = require(Shared.SharedUtilities)

local API = {}

API.StatusReceived = SharedUtilities.Signal.new("EWStatusReceived")

local commandRemote = EWRemotes.Get("DeviceCommand") :: RemoteEvent
local statusRemote = EWRemotes.Get("DeviceStatus") :: RemoteEvent

statusRemote.OnClientEvent:Connect(function(payload)
	API.StatusReceived:Fire(payload)
end)

function API.TogglePower(device: Instance)
	commandRemote:FireServer({ Action = "TogglePower", Device = device })
end

function API.SetPower(device: Instance, on: boolean)
	commandRemote:FireServer({ Action = "SetPower", Device = device, On = on })
end

function API.QueryStatus(device: Instance)
	commandRemote:FireServer({ Action = "QueryStatus", Device = device })
end

return API
