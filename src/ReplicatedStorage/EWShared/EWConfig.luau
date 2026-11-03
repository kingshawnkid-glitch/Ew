--!strict
--[[
	EWConfig
	Every tunable number in the EW simulation lives here. Nothing in the services
	hardcodes a range: links close or fail because of the link budget built from
	these parameters plus the actual map geometry.

	All values are GAME SIMULATION PARAMETERS. Where a default was taken from a
	public reference (ITU-R recommendation, public manufacturer datasheet) the
	comment says so; everything else is a gameplay-tuned value.

	To override at runtime without editing this file, set Attributes on the
	ServerScriptService.EWServer folder (see docs/PHASE1_GUIDE.md):
	  EW_PerformanceProfile  = "Development" | "Normal" | "HighPopulation" | "Auto"
	  EW_MetersPerStud       = number
	  EW_RunTests            = true   (Studio only, runs the Phase 1 test suite)
]]

local EWConfig = {}

EWConfig.Version = "1.0.0-phase1"

EWConfig.Units = {
	-- Geometric scale used for every RF calculation (distance, antenna height,
	-- wall thickness, Fresnel zones). 0.28 m/stud matches Roblox avatar scale.
	-- Raising it makes the world "RF-larger": free-space loss and terrain
	-- diffraction both grow, so ranges shrink relative to the map.
	MetersPerStud = 0.28,
	-- Map-compression factor applied ONLY to the distance term of the basic
	-- transmission loss (free-space / plane-earth). Terrain, structure and
	-- Fresnel geometry always use true geometry.
	--   1.0 = literal avatar scale (a 4,000-stud map is ~1.1 km: VHF/UHF voice
	--         then works almost everywhere that is not deeply obstructed)
	--   3.0 = default: Roblox maps treated as ~3x compressed for range, so
	--         ridges, distance and power level matter on typical map sizes.
	RangeScale = 3.0,
	MinLinkDistanceMeters = 1.0,
	-- Longest single raycast segment. Longer paths are split into segments.
	MaxRaySegmentStuds = 4000,
}

EWConfig.Registry = {
	FlagName = "EWDetectable", -- the mandatory BoolValue name
	TagName = "EWDevice", -- optional CollectionService integration (no BoolValue needed)
	RootOverrideAttribute = "EWDeviceRoot", -- set true on an ancestor to force it as the device root
	AntennaAttachmentName = "EWAntenna", -- optional Attachment marking the antenna feed point
	PersistSecondsAfterRemoval = 300, -- state (power, battery) survives respawn/re-insert by EWSerial
	MaxRootSearchDepth = 24,
}

EWConfig.Propagation = {
	-- Terrain/structure height field used for the diffraction profile.
	HeightCellStuds = 8,
	HeightProbeTop = 3000, -- downward probes start here (world Y)
	HeightProbeBottom = -600, -- and end here
	MaxHeightCells = 350000, -- cache is cleared when it grows beyond this (memory bound)
	HeightCacheMaxAgeSeconds = 300, -- full refresh so un-notified map edits heal (0 = never)
	MaxSkipHitsPerProbe = 4, -- dynamic/vegetation/ignored hits skipped per probe

	-- Profile sampling along the path.
	ProfileSpacingStuds = 16,
	ProfileMinSamples = 8,
	ProfileMaxSamples = 72,
	EndpointGroundExclusionStuds = 6, -- samples this close to an endpoint never count as diffraction edges
	EarthKFactor = 4 / 3, -- effective earth radius factor (standard atmosphere)
	MaxDiffractionDepth = 1, -- 1 = classic Deygout (principal + one secondary edge each side)

	-- Structure ray tracing.
	RespectCanCollide = true, -- non-collidable parts are decorative unless tagged
	RaycastCollisionGroup = nil :: string?, -- optional collision group for EW rays
	MinObstacleVolume = 0.6, -- parts smaller than this (stud^3) ...
	MinObstacleMaxDimension = 2.5, -- ...and with no side longer than this are ignored
	IgnoreTransparencyAbove = 0.98, -- invisible blockers are ignored unless given EWMaterial
	MaxObstaclesPerRay = 10,
	MaxPenetrationStudsPerObstacle = 60, -- thicker solids are treated as opaque (loss capped)
	EndpointClutterRadiusStuds = 40, -- obstacles this close to an endpoint must be passed on any path
	SpindleSubPaths = 2, -- extra Fresnel-ellipsoid sample paths (0, 2 or 4); profile may reduce
	SpindleReferenceMHz = 300, -- reference wavelength for spindle offsets (geometry is cached frequency-free)
	SpindleFresnelFraction = 0.6,
	SpindleMaxOffsetStuds = 14,
	SpindleOnlyWhenObstructed = false, -- low-priority links only sample spindles when the center ray hit something

	-- Terrain mass penetration (voxel checks under the surface).
	MaxVoxelReadsPerPath = 32,
	TerrainPenetrationMaxDb = 160,
	EndpointWaterProbeStuds = 64,

	-- Terrain-covered open space along the line of sight (tunnels, caves,
	-- bunkers). Low frequencies are below the waveguide cutoff of typical
	-- tunnels and die quickly; UHF and above propagate along straight tunnels.
	CavityLossDbPerMeterAt300MHz = 0.08,
	CavityFrequencyExponent = -1.5,
	CavityMaxLossDb = 80,

	-- Water (Roblox terrain water is treated as fresh water by default).
	WaterInterfaceLossDb = 6,
	WaterLossDbPerMeterAt100MHz = 1.8, -- low-loss dielectric approximation for fresh water
	WaterFrequencyExponent = 0.5,
	WaterMaxLossDb = 140,

	-- Vegetation (Weissberger modified exponential decay model), capped because a
	-- lower-loss path around the vegetation always exists (ITU-R P.833 guidance).
	VegetationTag = "EWVegetation",
	VegetationMaxLossDb = 30,
	VegetationMinFrequencyGHz = 0.03,

	-- Caching.
	PathQuantumStuds = 2, -- endpoints are quantized to this grid for cache keys
	PathCacheTtlSeconds = 8,
	PathCacheMaxEntries = 1500,
	RegionRevisionCellStuds = 256,
	AutoInvalidateMinPartSize = 8, -- anchored parts with a side >= this invalidate caches when added/removed

	-- Classification thresholds for PropagationLosses.Class.
	PartialObstructionMinDb = 1.5,
	ObstructedMinDb = 8,
	HeavyObstructionMinDb = 25,
}

EWConfig.Fading = {
	Enabled = true,
	ShadowDecorrelationStuds = 60,
	ShadowSigmaDb = { Unobstructed = 1.5, PartiallyObstructed = 3, Obstructed = 5, HeavilyObstructed = 7 },
	-- Rician K-factor (linear) per class; 0 = Rayleigh.
	RicianK = { Unobstructed = 12, PartiallyObstructed = 4, Obstructed = 1, HeavilyObstructed = 0 },
	MinDopplerHz = 0.15, -- environmental motion when both ends are stationary
	DeepFadeFloorDb = -30,
	EquipmentJitterMaxDb = 3, -- at Stability = 0
}

EWConfig.Noise = {
	-- ITU-R P.372 man-made noise: Fam(dB) = c - d * log10(f MHz).
	Categories = {
		City = { c = 76.8, d = 27.7 },
		Residential = { c = 72.5, d = 27.7 },
		Rural = { c = 67.2, d = 27.7 },
		QuietRural = { c = 53.6, d = 28.6 },
		Galactic = { c = 52.0, d = 23.0 },
	},
	DefaultCategory = "Rural",
	NoiseZoneTag = "EWNoiseZone",
	StormNoiseMaxDb = 20, -- atmospheric (lightning) noise boost at 30 MHz at storm intensity 1
}

EWConfig.Interference = {
	Enabled = true,
	MaxCandidateRangeStuds = 8000,
	MaxDetailedInterferers = 4, -- strongest N get a full terrain analysis, the rest use the basic loss
	AdjacentChannelRejectionDb = 60,
	AdjacentChannelSpan = 3, -- receiver bandwidths either side considered "adjacent"
	MinUsefulOverlap = 1e-4,
	ModulationMismatchPenaltyDb = 0, -- energy still interferes even if it cannot be demodulated
}

EWConfig.Quality = {
	-- Margin = SINR - RequiredSinr. Thresholds in dB (downward crossing uses -Hysteresis).
	Thresholds = { Clear = 15, Good = 8, Degraded = 3, Broken = -1 },
	HysteresisDb = 1.5,
	NoSignalMarginDb = -10,
	SensitivityFloorMarginDb = 3, -- received power this far below sensitivity = NoSignal
	ScoreMidpointDb = 4,
	ScoreSlope = 0.42,
	PacketLossMidpointDb = 0,
	PacketLossSlope = 0.75,
	SmoothingAlpha = 0.35, -- EMA factor for SmoothedMarginDb
}

EWConfig.Power = {
	TickSeconds = 1.0,
	BatteryDrainMultiplier = 1.0, -- gameplay scaling of all battery drain
	LowBatteryFraction = 0.15,
	CriticalBatteryFraction = 0.05,
	DefaultBootSeconds = 2.0,
	-- Spare batteries each player carries per life (server-side count; a game
	-- inventory can override with EquipmentPowerService:SetSpareBatteries).
	SpareBatteriesPerLife = 2,
}

EWConfig.Security = {
	InteractionDistanceStuds = 14, -- max distance for commanding a world device that nobody carries
	EnforceFactions = false, -- true: world devices with ElectronicFaction only obey players on a Team of that name
	-- Equipment carried by another player (e.g. a teammate's EW backpack) may be
	-- operated by players on the same Team standing within InteractionDistance.
	AllowTeammateControl = true,
	DeveloperUserIds = {} :: { number }, -- explicit developer allowlist
	DeveloperGroupId = 0, -- 0 = disabled; otherwise members at or above DeveloperMinRank are developers
	DeveloperMinRank = 254,
	StudioUsersAreDevelopers = true,
	CreatorIsDeveloper = true,
	RateLimits = {
		DeviceCommand = { Capacity = 8, RefillPerSecond = 2 },
		DiagnosticsRequest = { Capacity = 12, RefillPerSecond = 3 },
	},
	MaxStringLength = 64,
}

EWConfig.Diagnostics = {
	PublishIntervalSeconds = 1.0,
	MaxDevicesInSnapshot = 150,
	MaxLinksInSnapshot = 60,
	AllowDebugVisualsInLiveServers = false,
	AllowTestsInLiveServers = false,
	ToggleKey = Enum.KeyCode.F6,
	WarnRateLimitSeconds = 5,
}

EWConfig.Scheduler = {
	-- Link evaluation interval per priority (1 = critical, 2 = normal, 3 = background).
	LinkIntervals = { [1] = 0.2, [2] = 0.5, [3] = 2.0 },
	LinkMoveThresholdStuds = 3, -- endpoint movement that makes a watched link due immediately
	DevicePositionMinInterval = 0.2,
	DevicePositionMaxInterval = 2.0,
	MovingSpeedThreshold = 0.5, -- studs/s
	CacheMaintenanceSeconds = 5,
	ProfileCheckSeconds = 10,
}

-- Performance profiles. "Auto" = Development in Studio, Normal live, HighPopulation
-- when player count reaches HighPopulationPlayers.
EWConfig.DefaultPerformanceProfile = "Auto"
EWConfig.HighPopulationPlayers = 40
EWConfig.PerformanceProfiles = {
	Development = {
		FrameBudgetMs = 4.0,
		RaycastsPerFrame = 400,
		VoxelReadsPerFrame = 200,
		SpindleSubPaths = 4,
		ProfileMaxSamples = 72,
		MaxDetailedInterferers = 6,
		LinkIntervalMultiplier = 1.0,
	},
	Normal = {
		FrameBudgetMs = 2.5,
		RaycastsPerFrame = 160,
		VoxelReadsPerFrame = 96,
		SpindleSubPaths = 2,
		ProfileMaxSamples = 56,
		MaxDetailedInterferers = 4,
		LinkIntervalMultiplier = 1.0,
	},
	HighPopulation = {
		FrameBudgetMs = 1.6,
		RaycastsPerFrame = 90,
		VoxelReadsPerFrame = 48,
		SpindleSubPaths = 0,
		ProfileMaxSamples = 40,
		MaxDetailedInterferers = 2,
		LinkIntervalMultiplier = 1.6,
	},
}

-- Channel plan used to resolve string TransmissionChannel attributes.
-- Map/mission designers add their own named channels here (values in MHz).
EWConfig.ChannelPlan = {
	["TEST-VHF-1"] = 45.000,
	["TEST-VHF-2"] = 52.250,
	["TEST-UHF-1"] = 300.000,
	["TEST-LBAND-1"] = 1350.000,
	["JAM-SPOT-1"] = 45.000,
}

-- Test range (Studio only). Placed far from typical map content by default.
EWConfig.TestEnvironment = {
	Origin = Vector3.new(12000, 0, 12000),
	FolderName = "EWTestRange",
}

return EWConfig
