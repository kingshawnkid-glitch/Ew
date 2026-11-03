--!strict
--[[
	EWRemotes
	Single source of truth for client/server communication contracts.

	The SERVER creates the remotes (ReplicatedStorage.EWShared.Remotes) during
	bootstrap; clients only ever wait for them. Clients never send authoritative
	values - every request is validated by EWSecurityService.

	CONTRACTS (Phase 1)

	DeviceCommand        RemoteEvent     client -> server
	    payload = { Action: "TogglePower" | "SetPower" | "QueryStatus",
	                Device: Instance,          -- any instance inside the device
	                On: boolean? }             -- SetPower only
	    Server validates type/shape, rate limit, ownership or proximity.

	DeviceStatus         RemoteEvent     server -> one client
	    payload = { DisplayName: string, PowerState: string,
	                BatteryPercent: number?, Message: string?, Ok: boolean }

	DiagnosticsRequest   RemoteFunction  client -> server (developers only)
	    payload = { Action: "Snapshot" | "Subscribe" | "Unsubscribe" | "RunTests"
	                       | "SetDebugPaths" | "SetProfile" | "WatchLink" | "UnwatchLink",
	                Enabled: boolean?, Profile: string?, TxId: string?, RxId: string?,
	                WatchId: string? }
	    returns  { Ok: boolean, Error: string?, Data: any? }

	DiagnosticsStream    RemoteEvent     server -> subscribed developers only
	    payload = { Kind: "Snapshot" | "TestLog" | "DebugPaths", Data: any }
]]

local RunService = game:GetService("RunService")

local EWRemotes = {}

EWRemotes.FolderName = "Remotes"

EWRemotes.Definitions = {
	DeviceCommand = "RemoteEvent",
	DeviceStatus = "RemoteEvent",
	DiagnosticsRequest = "RemoteFunction",
	DiagnosticsStream = "RemoteEvent",
}

local function getFolder(create: boolean): Instance?
	local shared = script.Parent
	local folder = shared:FindFirstChild(EWRemotes.FolderName)
	if folder then
		return folder
	end
	if create then
		local f = Instance.new("Folder")
		f.Name = EWRemotes.FolderName
		f.Parent = shared
		return f
	end
	return shared:WaitForChild(EWRemotes.FolderName, 30)
end

-- Server: create all remotes (idempotent). Returns name -> instance.
function EWRemotes.CreateAll(): { [string]: Instance }
	assert(RunService:IsServer(), "EWRemotes.CreateAll is server-only")
	local folder = getFolder(true) :: Instance
	local out = {}
	for name, className in pairs(EWRemotes.Definitions) do
		local existing = folder:FindFirstChild(name)
		if existing and existing.ClassName ~= className then
			existing:Destroy()
			existing = nil
		end
		if not existing then
			local remote = Instance.new(className)
			remote.Name = name
			remote.Parent = folder
			existing = remote
		end
		out[name] = existing :: Instance
	end
	return out
end

-- Client or server: get one remote, waiting for the server to create it.
function EWRemotes.Get(name: string, timeoutSeconds: number?): Instance?
	assert(EWRemotes.Definitions[name] ~= nil, "Unknown EW remote: " .. name)
	local folder = getFolder(RunService:IsServer())
	if not folder then
		return nil
	end
	return folder:WaitForChild(name, timeoutSeconds or 30)
end

return EWRemotes
