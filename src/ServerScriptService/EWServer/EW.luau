--[[
	EW (server facade)
	The one module other server scripts (map logic, later equipment phases,
	weather systems) require to reach the running EW services.

	    local EW = require(game.ServerScriptService.EWServer.EW)
	    local ctx = EW.WaitForReady()
	    ctx.Terrain:NotifyTerrainChanged(minCorner, maxCorner)
	    local record = ctx.Registry:RegisterDevice(myRadioTool, { ElectronicType = "Communications" })

	Context fields: Config, Remotes, Diagnostics, Scheduler, Environment, Terrain,
	Registry, Power, Quality, RF, Security, DeviceCommands, Radio (Phase 2), Root.
	Services are singletons: requiring a service module directly returns the
	same instance, but only use it after WaitForReady().
]]

local EW = {}

EW.Ready = false
EW.Context = nil

local readyEvent = Instance.new("BindableEvent")

function EW.WaitForReady(timeoutSeconds: number?)
	if EW.Ready then
		return EW.Context
	end
	if timeoutSeconds then
		local done = false
		local thread = coroutine.running()
		local connection
		connection = readyEvent.Event:Connect(function()
			if not done then
				done = true
				connection:Disconnect()
				task.spawn(thread)
			end
		end)
		task.delay(timeoutSeconds, function()
			if not done then
				done = true
				connection:Disconnect()
				task.spawn(thread)
			end
		end)
		coroutine.yield()
		return EW.Context
	end
	readyEvent.Event:Wait()
	return EW.Context
end

function EW._SetContext(context)
	EW.Context = context
	EW.Ready = true
	readyEvent:Fire()
end

return EW
