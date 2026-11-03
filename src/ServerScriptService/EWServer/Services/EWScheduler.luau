--[[
	EWScheduler
	One Heartbeat-driven scheduler for all EW server work.

	* Jobs declare an interval and a priority. Each frame, due jobs run in
	  priority order while the per-frame time budget lasts.
	* Incremental jobs (link evaluation, device positions) receive the remaining
	  budget and must stop when it is spent; unfinished work carries over.
	* Raycast and voxel-read budgets are reset every frame and consumed by the
	  TerrainPropagationService, which degrades gracefully (cache / profile-only)
	  instead of exceeding them.
	* Every job runs inside pcall and a MicroProfiler label ("EW:<job>") so
	  costs are visible in the Roblox MicroProfiler and in EW diagnostics.

	API
	  Scheduler:Init(context)
	  Scheduler:AddJob(name, intervalSeconds, priority, callback, options) -> Job
	      callback(dtSinceLastRun: number, budgetSeconds: number, job: Job)
	      options = { Essential: boolean? }  -- essential jobs run even when over budget
	  Scheduler:SetProfile(name)
	  Scheduler:Start() / Scheduler:Stop()
	  Scheduler:TryConsumeRaycasts(n) -> boolean      (also :ConsumeRaycasts(n) forced)
	  Scheduler:TryConsumeVoxelReads(n) -> boolean
	  Scheduler:GetStats() -> table
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local EWScheduler = {}

export type Job = {
	Name: string,
	Interval: number,
	Priority: number,
	Callback: (number, number, any) -> (),
	Essential: boolean,
	Enabled: boolean,
	NextRun: number,
	LastRun: number,
	Runs: number,
	Skipped: number,
	Errors: number,
	LastError: string?,
	AvgCostMs: number,
	MaxCostMs: number,
}

local context
local config
local jobs: { Job } = {}
local heartbeatConnection: RBXScriptConnection? = nil
local activeProfileName = "Normal"
local activeProfile = nil

local raycastsThisFrame = 0
local raycastBudgetThisFrame = 0
local voxelReadsThisFrame = 0
local voxelBudgetThisFrame = 0

local stats = {
	Frames = 0,
	FrameCostMsAvg = 0,
	FrameCostMsMax = 0,
	OverBudgetFrames = 0,
	RaycastsTotal = 0,
	RaycastsLastSecond = 0,
	VoxelReadsTotal = 0,
	VoxelReadsLastSecond = 0,
	BudgetDenials = 0,
}
local secondWindowStart = os.clock()
local raycastsWindow = 0
local voxelWindow = 0

local function resolveProfileName(requested: string): string
	if requested == "Auto" then
		if RunService:IsStudio() then
			return "Development"
		end
		if #Players:GetPlayers() >= config.HighPopulationPlayers then
			return "HighPopulation"
		end
		return "Normal"
	end
	if config.PerformanceProfiles[requested] then
		return requested
	end
	warn(string.format("[EW] Unknown performance profile '%s', using Normal", tostring(requested)))
	return "Normal"
end

function EWScheduler:Init(ctx)
	context = ctx
	config = ctx.Config
	self.RequestedProfile = config.DefaultPerformanceProfile
	self:SetProfile(self.RequestedProfile)
end

function EWScheduler:SetProfile(name: string)
	self.RequestedProfile = name
	activeProfileName = resolveProfileName(name)
	activeProfile = config.PerformanceProfiles[activeProfileName]
	if context and context.Diagnostics then
		context.Diagnostics:Log("Scheduler", "Performance profile: " .. activeProfileName)
	end
end

function EWScheduler:GetProfile()
	return activeProfile, activeProfileName
end

function EWScheduler:AddJob(name: string, interval: number, priority: number, callback, options): Job
	local job: Job = {
		Name = name,
		Interval = interval,
		Priority = priority,
		Callback = callback,
		Essential = options ~= nil and options.Essential == true,
		Enabled = true,
		NextRun = os.clock() + math.random() * math.min(interval, 0.5), -- desynchronize job phases
		LastRun = os.clock(),
		Runs = 0,
		Skipped = 0,
		Errors = 0,
		LastError = nil,
		AvgCostMs = 0,
		MaxCostMs = 0,
	}
	table.insert(jobs, job)
	table.sort(jobs, function(a, b)
		return a.Priority < b.Priority
	end)
	return job
end

function EWScheduler:RemoveJob(job: Job)
	local index = table.find(jobs, job)
	if index then
		table.remove(jobs, index)
	end
end

function EWScheduler:TryConsumeRaycasts(n: number): boolean
	if raycastsThisFrame + n > raycastBudgetThisFrame then
		stats.BudgetDenials += 1
		return false
	end
	raycastsThisFrame += n
	return true
end

-- Forced consumption (on-demand evaluations such as tests or PTT events) is
-- still counted so diagnostics reflect true raycast usage.
function EWScheduler:ConsumeRaycasts(n: number)
	raycastsThisFrame += n
end

function EWScheduler:RemainingRaycasts(): number
	return math.max(0, raycastBudgetThisFrame - raycastsThisFrame)
end

function EWScheduler:TryConsumeVoxelReads(n: number): boolean
	if voxelReadsThisFrame + n > voxelBudgetThisFrame then
		stats.BudgetDenials += 1
		return false
	end
	voxelReadsThisFrame += n
	return true
end

function EWScheduler:ConsumeVoxelReads(n: number)
	voxelReadsThisFrame += n
end

function EWScheduler:RemainingVoxelReads(): number
	return math.max(0, voxelBudgetThisFrame - voxelReadsThisFrame)
end

local function endFrameAccounting()
	stats.RaycastsTotal += raycastsThisFrame
	stats.VoxelReadsTotal += voxelReadsThisFrame
	raycastsWindow += raycastsThisFrame
	voxelWindow += voxelReadsThisFrame
	local now = os.clock()
	if now - secondWindowStart >= 1 then
		local span = now - secondWindowStart
		stats.RaycastsLastSecond = math.floor(raycastsWindow / span + 0.5)
		stats.VoxelReadsLastSecond = math.floor(voxelWindow / span + 0.5)
		raycastsWindow = 0
		voxelWindow = 0
		secondWindowStart = now
	end
end

function EWScheduler:Step()
	-- Usage that happened between frames (on-demand calls) is attributed to this frame.
	endFrameAccounting()
	raycastsThisFrame = 0
	voxelReadsThisFrame = 0
	raycastBudgetThisFrame = activeProfile.RaycastsPerFrame
	voxelBudgetThisFrame = activeProfile.VoxelReadsPerFrame

	local frameStart = os.clock()
	local budget = activeProfile.FrameBudgetMs / 1000
	local deadline = frameStart + budget

	for _, job in ipairs(jobs) do
		if job.Enabled then
			local now = os.clock()
			if now >= job.NextRun then
				local remaining = deadline - now
				if remaining <= 0 and not job.Essential then
					job.Skipped += 1
				else
					local t0 = os.clock()
					debug.profilebegin("EW:" .. job.Name)
					local ok, err = pcall(job.Callback, now - job.LastRun, math.max(remaining, 0.0002), job)
					debug.profileend()
					local costMs = (os.clock() - t0) * 1000
					job.Runs += 1
					job.LastRun = now
					job.NextRun = now + job.Interval
					job.AvgCostMs = job.AvgCostMs * 0.9 + costMs * 0.1
					if costMs > job.MaxCostMs then
						job.MaxCostMs = costMs
					end
					if not ok then
						job.Errors += 1
						job.LastError = tostring(err)
						if context and context.Diagnostics then
							context.Diagnostics:Warn("Scheduler", string.format("Job %s failed: %s", job.Name, tostring(err)))
						else
							warn("[EW] job failed", job.Name, err)
						end
					end
				end
			end
		end
	end

	local frameCostMs = (os.clock() - frameStart) * 1000
	stats.Frames += 1
	stats.FrameCostMsAvg = stats.FrameCostMsAvg * 0.98 + frameCostMs * 0.02
	if frameCostMs > stats.FrameCostMsMax then
		stats.FrameCostMsMax = frameCostMs
	end
	if frameCostMs > activeProfile.FrameBudgetMs then
		stats.OverBudgetFrames += 1
	end
end

function EWScheduler:Start()
	if heartbeatConnection then
		return
	end
	raycastBudgetThisFrame = activeProfile.RaycastsPerFrame
	voxelBudgetThisFrame = activeProfile.VoxelReadsPerFrame
	heartbeatConnection = RunService.Heartbeat:Connect(function()
		self:Step()
	end)
	-- Re-resolve "Auto" periodically so player-count changes move between profiles.
	self:AddJob("ProfileCheck", config.Scheduler.ProfileCheckSeconds, 9, function()
		if self.RequestedProfile == "Auto" then
			local resolved = resolveProfileName("Auto")
			if resolved ~= activeProfileName then
				self:SetProfile("Auto")
			end
		end
	end)
end

function EWScheduler:Stop()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
end

function EWScheduler:ResetMaxima()
	stats.FrameCostMsMax = 0
	for _, job in ipairs(jobs) do
		job.MaxCostMs = 0
	end
end

function EWScheduler:GetStats()
	local jobStats = {}
	for _, job in ipairs(jobs) do
		table.insert(jobStats, {
			Name = job.Name,
			Interval = job.Interval,
			Runs = job.Runs,
			Skipped = job.Skipped,
			Errors = job.Errors,
			LastError = job.LastError,
			AvgCostMs = job.AvgCostMs,
			MaxCostMs = job.MaxCostMs,
		})
	end
	return {
		Profile = activeProfileName,
		RequestedProfile = self.RequestedProfile,
		FrameBudgetMs = activeProfile.FrameBudgetMs,
		RaycastsPerFrame = activeProfile.RaycastsPerFrame,
		Frames = stats.Frames,
		FrameCostMsAvg = stats.FrameCostMsAvg,
		FrameCostMsMax = stats.FrameCostMsMax,
		OverBudgetFrames = stats.OverBudgetFrames,
		RaycastsTotal = stats.RaycastsTotal,
		RaycastsLastSecond = stats.RaycastsLastSecond,
		VoxelReadsTotal = stats.VoxelReadsTotal,
		VoxelReadsLastSecond = stats.VoxelReadsLastSecond,
		BudgetDenials = stats.BudgetDenials,
		Jobs = jobStats,
	}
end

return EWScheduler
