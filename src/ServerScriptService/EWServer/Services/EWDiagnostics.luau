--[[
	EWDiagnostics
	Developer-only observability for the EW simulation.

	  * Log / Warn ring buffer (warnings rate-limited per message key)
	  * Snapshots: registry counters, devices, watched links with full link
	    budget breakdowns and degradation explanations, scheduler cost per job,
	    raycast / voxel usage, cache statistics, security rejections
	  * Streaming to subscribed developers via DiagnosticsStream with per-device
	    delta rows (full refresh every FullRefreshSeconds)
	  * Debug path data (signal paths + obstruction points) rendered LOCALLY by
	    the developer client - nothing is created in the shared Workspace, so
	    ordinary players never see hidden information
	  * DiagnosticsRequest RemoteFunction handler (Snapshot, Subscribe, RunTests,
	    SetDebugPaths, SetProfile, WatchLink, UnwatchLink)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local EWDiagnostics = {}

local context
local config
local logBuffer: { string } = {}
local LOG_LIMIT = 200
local lastWarn: { [string]: number } = {}
local counters: { [string]: number } = {}

type Subscriber = { Player: Player, DebugPaths: boolean, RowHashes: { [string]: string }, LastFull: number }
local subscribers: { [Player]: Subscriber } = {}
local FULL_REFRESH_SECONDS = 10
local testRunning = false

local function push(line: string)
	table.insert(logBuffer, line)
	if #logBuffer > LOG_LIMIT then
		table.remove(logBuffer, 1)
	end
end

function EWDiagnostics:Init(ctx)
	context = ctx
	config = ctx.Config
end

function EWDiagnostics:Log(category: string, message: string)
	local line = string.format("[%7.1f] %s: %s", os.clock(), category, message)
	push(line)
	if RunService:IsStudio() then
		print("[EW] " .. category .. ": " .. message)
	end
end

function EWDiagnostics:Warn(category: string, message: string)
	local key = category .. message
	local now = os.clock()
	local last = lastWarn[key]
	if last and now - last < config.Diagnostics.WarnRateLimitSeconds then
		self:Increment("SuppressedWarnings")
		return
	end
	lastWarn[key] = now
	push(string.format("[%7.1f] WARN %s: %s", now, category, message))
	warn("[EW] " .. category .. ": " .. message)
end

function EWDiagnostics:Increment(name: string, amount: number?)
	counters[name] = (counters[name] or 0) + (amount or 1)
end

local function finite(x: any): any
	if type(x) ~= "number" then
		return x
	end
	if x ~= x then
		return 0
	elseif x == math.huge then
		return 999
	elseif x == -math.huge then
		return -999
	end
	return math.floor(x * 10 + 0.5) / 10
end

local function deviceRow(record)
	local emitter = record.Emitters[1]
	local battery = context.Power:GetBatteryFraction(record)
	return {
		Id = record.Id,
		Name = record.DisplayName,
		Type = record.ElectronicType,
		Class = record.DetectionClass,
		Detectable = record.Detectable,
		Power = record.PowerState,
		Battery = if battery then finite(battery * 100) else nil,
		Owner = record.OwnerUserId,
		InWorld = record.InWorld,
		Position = Vector3.new(finite(record.Position.X), finite(record.Position.Y), finite(record.Position.Z)),
		Emitting = emitter ~= nil and emitter.Transmitting and record.PowerState == "On",
		FrequencyMHz = emitter and emitter.FrequencyMHz or 0,
		Profile = emitter and emitter.ProfileId or "",
		TxPowerDbm = emitter and finite(emitter.TxPowerDbm) or 0,
		Sources = string.format(
			"%s%s%s",
			if record.RegistrationSources.Flag then "F" else "-",
			if record.RegistrationSources.Tag then "T" else "-",
			if record.RegistrationSources.API then "A" else "-"
		),
		Notes = if record.ConfigurationNotes and #record.ConfigurationNotes > 0 then table.concat(record.ConfigurationNotes, ",") else nil,
	}
end

local function rowHash(row): string
	return string.format(
		"%s|%s|%s|%s|%s|%s|%.0f|%.0f|%.0f|%s",
		row.Name,
		tostring(row.Detectable),
		row.Power,
		tostring(row.Battery),
		tostring(row.Emitting),
		tostring(row.InWorld),
		row.Position.X,
		row.Position.Y,
		row.Position.Z,
		tostring(row.FrequencyMHz)
	)
end

local function linkRow(watch)
	local r = watch.LastResult
	if not r then
		return { Id = watch.Id, Label = watch.Label, State = "Pending" }
	end
	local p = r.Propagation
	local explanation = {}
	if p then
		for i, line in ipairs(p.Explanation) do
			if i > 8 then
				break
			end
			table.insert(explanation, line)
		end
	end
	return {
		Id = watch.Id,
		Label = watch.Label,
		TxId = watch.TxId,
		RxId = watch.RxId,
		State = r.Quality.State,
		Readability = r.Quality.Readability,
		Strength = r.Quality.Strength,
		MarginDb = finite(r.Quality.MarginDb),
		SinrDb = finite(r.SinrDb),
		SnrDb = finite(r.SnrDb),
		RxDbm = finite(r.InBandSignalDbm),
		NoiseDbm = finite(r.NoiseFloorDbm),
		InterferenceDbm = finite(r.InterferenceDbm),
		FrequencyMHz = r.FrequencyMHz,
		DistanceStuds = finite(r.DistanceStuds),
		EirpDbm = finite(r.EirpDbm),
		BasicDb = finite(r.BasicLossDb),
		BasicModel = r.BasicModel,
		ExcessDb = p and finite(p.ExcessDb) or nil,
		DiffractionDb = p and finite(p.DiffractionDb) or nil,
		StructureDb = p and finite(p.StructureDb) or nil,
		TerrainDb = p and finite(p.TerrainPenetrationDb) or nil,
		VegetationDb = p and finite(p.VegetationDb) or nil,
		WaterDb = p and finite(p.WaterDb) or nil,
		Class = p and p.Class or "?",
		Dominant = p and p.DominantPath or "?",
		FadingDb = finite(r.ShadowFadingDb + r.FastFadingDb + r.EquipmentJitterDb),
		PolarizationDb = finite(r.PolarizationLossDb),
		WeatherDb = finite(r.WeatherLossDb),
		TxActive = r.TxActive,
		Mode = r.AnalysisMode,
		Stale = r.Stale,
		Reasons = table.concat(r.Reasons, ","),
		Explanation = explanation,
		Evaluations = watch.Evaluations,
	}
end

function EWDiagnostics:BuildSnapshot(subscriber: Subscriber?)
	local now = os.clock()
	local full = subscriber == nil or (now - subscriber.LastFull) >= FULL_REFRESH_SECONDS
	local devices = {}
	local removed = {}
	local seen = {}
	local list = context.Registry:GetDeviceList()
	for i, record in ipairs(list) do
		if i > config.Diagnostics.MaxDevicesInSnapshot then
			break
		end
		local row = deviceRow(record)
		seen[record.Id] = true
		if subscriber then
			local hash = rowHash(row)
			if full or subscriber.RowHashes[record.Id] ~= hash then
				subscriber.RowHashes[record.Id] = hash
				table.insert(devices, row)
			end
		else
			table.insert(devices, row)
		end
	end
	if subscriber then
		for id in pairs(subscriber.RowHashes) do
			if not seen[id] then
				subscriber.RowHashes[id] = nil
				table.insert(removed, id)
			end
		end
		if full then
			subscriber.LastFull = now
		end
	end
	local links = {}
	for i, watch in ipairs(context.RF:GetWatches()) do
		if i > config.Diagnostics.MaxLinksInSnapshot then
			break
		end
		table.insert(links, linkRow(watch))
	end
	local tail = {}
	for i = math.max(1, #logBuffer - 30), #logBuffer do
		table.insert(tail, logBuffer[i])
	end
	local schedulerStats = context.Scheduler:GetStats()
	for _, job in ipairs(schedulerStats.Jobs) do
		job.AvgCostMs = finite(job.AvgCostMs)
		job.MaxCostMs = finite(job.MaxCostMs)
	end
	schedulerStats.FrameCostMsAvg = finite(schedulerStats.FrameCostMsAvg)
	schedulerStats.FrameCostMsMax = finite(schedulerStats.FrameCostMsMax)
	local terrainStats = context.Terrain:GetStats()
	terrainStats.AnalysisMsAvg = finite(terrainStats.AnalysisMsAvg)
	terrainStats.AnalysisMsMax = finite(terrainStats.AnalysisMsMax)
	terrainStats.CacheHitRate = finite(terrainStats.CacheHitRate * 100)
	terrainStats.HeightCacheAgeSeconds = finite(terrainStats.HeightCacheAgeSeconds)
	local rfStats = context.RF:GetStats()
	rfStats.EvaluationMsAvg = finite(rfStats.EvaluationMsAvg)
	rfStats.EvaluationMsMax = finite(rfStats.EvaluationMsMax)

	return {
		Version = config.Version,
		Time = finite(now),
		Full = full,
		Registry = context.Registry:GetCounters(),
		Scheduler = schedulerStats,
		Terrain = terrainStats,
		RF = rfStats,
		Security = context.Security:GetStats(),
		Environment = context.Environment:GetConditions(),
		Counters = table.clone(counters),
		Devices = devices,
		RemovedDevices = removed,
		Links = links,
		Log = tail,
		MetersPerStud = config.Units.MetersPerStud,
		TestRunning = testRunning,
	}
end

local function debugVisualsAllowed(): boolean
	return RunService:IsStudio() or config.Diagnostics.AllowDebugVisualsInLiveServers
end

local function buildDebugPaths()
	local paths = {}
	for i, watch in ipairs(context.RF:GetWatches()) do
		if i > 24 then
			break
		end
		local tx = context.Registry:GetDevice(watch.TxId)
		local rx = context.Registry:GetDevice(watch.RxId)
		if tx and rx and watch.LastResult and watch.LastResult.Propagation then
			-- Cache hit in the common case; never forced, so it cannot blow the budget.
			local geometry = context.Terrain:AnalyzePath(tx.Position, rx.Position, { ExcludeInstances = { tx.Root, rx.Root } })
			if geometry then
				local path = context.Terrain:BuildDebugPath(geometry, watch.LastResult.Propagation)
				path.State = watch.LastResult.Quality.State
				path.Label = watch.Label
				table.insert(paths, path)
			end
		end
	end
	return paths
end

function EWDiagnostics:Stream(player: Player, kind: string, data: any)
	local remote = context.Remotes.DiagnosticsStream :: RemoteEvent
	if context.Security:IsDeveloper(player) then
		remote:FireClient(player, { Kind = kind, Data = data })
	end
end

function EWDiagnostics:StreamToSubscribers(kind: string, data: any)
	for player in pairs(subscribers) do
		self:Stream(player, kind, data)
	end
end

local REQUEST_SCHEMA = {
	Action = {
		Type = "string",
		Enum = { "Snapshot", "Subscribe", "Unsubscribe", "RunTests", "SetDebugPaths", "SetProfile", "WatchLink", "UnwatchLink", "ResetMaxima" },
	},
	Enabled = { Type = "boolean", Optional = true },
	Profile = { Type = "string", Optional = true, Enum = { "Auto", "Development", "Normal", "HighPopulation" } },
	TxId = { Type = "string", Optional = true, MaxLength = 24 },
	RxId = { Type = "string", Optional = true, MaxLength = 24 },
	WatchId = { Type = "string", Optional = true, MaxLength = 24 },
}

function EWDiagnostics:RunTests(requester: Player?)
	if testRunning then
		return false, "TESTS_ALREADY_RUNNING"
	end
	if not (RunService:IsStudio() or config.Diagnostics.AllowTestsInLiveServers) then
		return false, "TESTS_STUDIO_ONLY"
	end
	local testsFolder = context.Root:FindFirstChild("Tests")
	local runnerModule = testsFolder and testsFolder:FindFirstChild("EWTestRunner")
	if not runnerModule then
		return false, "TEST_RUNNER_MISSING"
	end
	testRunning = true
	task.spawn(function()
		local runner = require(runnerModule)
		local ok, err = pcall(function()
			runner.RunAll(context, function(line: string)
				self:Log("Test", line)
				if requester and requester.Parent then
					self:Stream(requester, "TestLog", line)
				end
			end)
		end)
		if not ok then
			self:Warn("Test", "Test runner crashed: " .. tostring(err))
			if requester and requester.Parent then
				self:Stream(requester, "TestLog", "TEST RUNNER CRASHED: " .. tostring(err))
			end
		end
		testRunning = false
	end)
	return true, nil
end

local function handleRequest(player: Player, payload: any)
	local security = context.Security
	if not security:IsDeveloper(player) then
		security:Reject(player, "DiagnosticsRequest", "NOT_DEVELOPER")
		return { Ok = false, Error = "NOT_AUTHORIZED" }
	end
	if not security:CheckRate(player, "DiagnosticsRequest") then
		security:Reject(player, "DiagnosticsRequest", "RATE_LIMIT")
		return { Ok = false, Error = "RATE_LIMIT" }
	end
	local valid, why = security:ValidatePayload(payload, REQUEST_SCHEMA)
	if not valid then
		security:Reject(player, "DiagnosticsRequest", why or "INVALID")
		return { Ok = false, Error = why }
	end
	local action = payload.Action
	if action == "Snapshot" then
		return { Ok = true, Data = EWDiagnostics:BuildSnapshot(nil) }
	elseif action == "Subscribe" then
		subscribers[player] = subscribers[player] or { Player = player, DebugPaths = false, RowHashes = {}, LastFull = 0 }
		return { Ok = true }
	elseif action == "Unsubscribe" then
		subscribers[player] = nil
		return { Ok = true }
	elseif action == "SetDebugPaths" then
		local sub = subscribers[player]
		if not sub then
			return { Ok = false, Error = "NOT_SUBSCRIBED" }
		end
		if payload.Enabled and not debugVisualsAllowed() then
			return { Ok = false, Error = "DEBUG_VISUALS_STUDIO_ONLY" }
		end
		sub.DebugPaths = payload.Enabled == true
		return { Ok = true }
	elseif action == "SetProfile" then
		if not payload.Profile then
			return { Ok = false, Error = "MISSING_PROFILE" }
		end
		context.Scheduler:SetProfile(payload.Profile)
		return { Ok = true }
	elseif action == "RunTests" then
		local ok, err = EWDiagnostics:RunTests(player)
		return { Ok = ok, Error = err }
	elseif action == "WatchLink" then
		if not payload.TxId or not payload.RxId then
			return { Ok = false, Error = "MISSING_IDS" }
		end
		local id = context.RF:WatchLink(payload.TxId, payload.RxId, { Priority = 2 })
		return { Ok = id ~= nil, Data = id, Error = if id then nil else "UNKNOWN_DEVICE" }
	elseif action == "UnwatchLink" then
		if not payload.WatchId then
			return { Ok = false, Error = "MISSING_WATCH_ID" }
		end
		context.RF:UnwatchLink(payload.WatchId, "Developer")
		return { Ok = true }
	elseif action == "ResetMaxima" then
		context.Scheduler:ResetMaxima()
		return { Ok = true }
	end
	return { Ok = false, Error = "UNKNOWN_ACTION" }
end

function EWDiagnostics:Start()
	local request = context.Remotes.DiagnosticsRequest :: RemoteFunction
	request.OnServerInvoke = function(player, payload)
		local ok, result = pcall(handleRequest, player, payload)
		if ok then
			return result
		end
		EWDiagnostics:Warn("Diagnostics", "Request handler error: " .. tostring(result))
		return { Ok = false, Error = "SERVER_ERROR" }
	end
	Players.PlayerRemoving:Connect(function(player)
		subscribers[player] = nil
	end)
	context.Scheduler:AddJob("DiagnosticsPublish", config.Diagnostics.PublishIntervalSeconds, 9, function()
		if next(subscribers) == nil then
			return
		end
		local paths = nil
		for player, sub in pairs(subscribers) do
			if not context.Security:IsDeveloper(player) then
				subscribers[player] = nil
			else
				self:Stream(player, "Snapshot", self:BuildSnapshot(sub))
				if sub.DebugPaths and debugVisualsAllowed() then
					paths = paths or buildDebugPaths()
					self:Stream(player, "DebugPaths", paths)
				end
			end
		end
	end)
	-- Surface security rejections in the counters panel.
	context.Security.Rejected:Connect(function()
		self:Increment("SecurityRejections")
	end)
end

return EWDiagnostics
