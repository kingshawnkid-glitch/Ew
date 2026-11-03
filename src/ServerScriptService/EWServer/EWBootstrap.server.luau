--[[
	EWBootstrap (Script)
	Creates remotes, wires every EW service through a shared context
	(dependency injection - no service requires another service directly, so
	there are no circular dependencies), then starts the scheduler.

	INIT ORDER   Diagnostics -> Scheduler -> Environment -> Terrain -> Registry
	             -> Power -> Quality -> RF -> Security -> DeviceCommands
	START ORDER  Environment -> Terrain -> Registry -> Power -> RF -> Security
	             -> DeviceCommands -> Diagnostics -> Scheduler (heartbeat last)

	Attributes on this script's parent folder (EWServer):
	  EW_PerformanceProfile  string   "Auto" | "Development" | "Normal" | "HighPopulation"
	  EW_MetersPerStud       number   RF geometric scale override
	  EW_RunTests            boolean  Studio: run the Phase 1 test suite (also settable at runtime)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local root = script.Parent
local Services = root:WaitForChild("Services")
local Shared = ReplicatedStorage:WaitForChild("EWShared")

local Config = require(Shared.EWConfig)
local EWRemotes = require(Shared.EWRemotes)
local EW = require(root:WaitForChild("EW"))

-- Attribute overrides (read once at boot).
local metersPerStud = root:GetAttribute("EW_MetersPerStud")
if type(metersPerStud) == "number" and metersPerStud > 0 then
	Config.Units.MetersPerStud = metersPerStud
end
local rangeScale = root:GetAttribute("EW_RangeScale")
if type(rangeScale) == "number" and rangeScale > 0 then
	Config.Units.RangeScale = rangeScale
end
local requestedProfile = root:GetAttribute("EW_PerformanceProfile")
if type(requestedProfile) == "string" then
	Config.DefaultPerformanceProfile = requestedProfile
end

local context = {
	Config = Config,
	Root = root,
	Remotes = EWRemotes.CreateAll(),
}

context.Diagnostics = require(Services.EWDiagnostics)
context.Scheduler = require(Services.EWScheduler)
context.Environment = require(Services.EnvironmentalConditionsAdapter)
context.Terrain = require(Services.TerrainPropagationService)
context.Registry = require(Services.ElectronicDeviceRegistry)
context.Power = require(Services.EquipmentPowerService)
context.Quality = require(Services.SignalQualityService)
context.RF = require(Services.RFSimulationService)
context.Security = require(Services.EWSecurityService)
context.DeviceCommands = require(Services.DeviceCommandService)

local INIT_ORDER = {
	"Diagnostics",
	"Scheduler",
	"Environment",
	"Terrain",
	"Registry",
	"Power",
	"Quality",
	"RF",
	"Security",
	"DeviceCommands",
}
local START_ORDER = {
	"Environment",
	"Terrain",
	"Registry",
	"Power",
	"RF",
	"Security",
	"DeviceCommands",
	"Diagnostics",
}

for _, name in ipairs(INIT_ORDER) do
	context[name]:Init(context)
end
for _, name in ipairs(START_ORDER) do
	local service = context[name]
	if service.Start then
		service:Start()
	end
end
context.Scheduler:Start()

context.Diagnostics:Log(
	"Bootstrap",
	string.format(
		"EW %s ready: %d devices registered, profile %s, %.2f m/stud, range scale %.1f",
		Config.Version,
		context.Registry:Count(),
		select(2, context.Scheduler:GetProfile()),
		Config.Units.MetersPerStud,
		Config.Units.RangeScale
	)
)

EW._SetContext(context)

local function maybeRunTests()
	if root:GetAttribute("EW_RunTests") == true then
		root:SetAttribute("EW_RunTests", false)
		local ok, err = context.Diagnostics:RunTests(nil)
		if not ok then
			warn("[EW] Tests not started: " .. tostring(err))
		end
	end
end
root:GetAttributeChangedSignal("EW_RunTests"):Connect(maybeRunTests)
task.defer(maybeRunTests)
