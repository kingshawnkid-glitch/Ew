--[[
	TerrainPropagationService
	Turns real map geometry (Roblox Terrain + BaseParts) between two endpoints
	into RF propagation losses. This is the module that makes mountains, valleys,
	buildings, forests, tunnels and water matter.

	TWO STAGES
	  1. AnalyzePath(a, b, options) -> PathGeometry          (expensive, CACHED)
	       Frequency-independent geometry gathered with documented spatial APIs:
	         * Workspace:Raycast + RaycastParams / RaycastResult
	         * Terrain:ReadVoxels (terrain solidity / water under the LOS)
	       - Height profile: downward probes into a cached height field
	         (terrain + anchored static structures), sampled along the path
	       - Terrain mass under the line of sight, verified voxel-by-voxel so
	         caves, tunnels, arches and basements are handled correctly
	       - Structure penetrations: forward ray + reverse include-filtered ray
	         per obstacle to measure entry/exit thickness, cumulative walls,
	         cavities inside MeshParts/Unions handled by a forward include ray
	       - Fresnel "spindle" sub-paths (bounded multi-ray sampling) through
	         the first-Fresnel ellipsoid to detect partial obstruction by edges
	       - Vegetation depth (tagged foliage and LeafyGrass/Grass parts)
	       - Water along the path and at submerged endpoints
	  2. ComputeLosses(geometry, frequencyMHz) -> PropagationLosses   (cheap math)
	       - Deygout multi-edge diffraction (ITU-R P.526 J(v)) over the profile
	       - Through-path: terrain penetration + structures + vegetation + water
	       - Over-the-top path: diffraction + clutter around the endpoints
	       - The two paths are combined as incoherent alternative paths, so the
	         least-loss path dominates (signals go OVER a hill rather than
	         THROUGH it, but THROUGH a thin wall rather than over a tall building)

	WHAT IS NOT SIMULATED (documented, not faked)
	  * No specular reflection / multipath ray tracing, no exact UTD diffraction,
	    no waveguide propagation along tunnels. Multipath is represented
	    statistically by the fading model in RFSimulationService.

	CACHING / INVALIDATION
	  * Height field cells (HeightCellStuds) are cached; cleared by region on
	    NotifyTerrainChanged / InvalidateRegion, automatically when large
	    anchored parts are added/removed, and fully after HeightCacheMaxAgeSeconds.
	  * PathGeometry is cached per quantized endpoint pair (symmetric) with a TTL
	    and a region-revision stamp, so map edits invalidate affected paths only.

	PUBLIC API
	  TPS:AnalyzePath(a, b, options) -> PathGeometry?
	      options = { ExcludeInstances: {Instance}?, Priority: number?, Force: boolean?,
	                  SpindleSubPaths: number?, NoCache: boolean? }
	  TPS:ComputeLosses(geometry, frequencyMHz) -> PropagationLosses
	  TPS:SampleGround(x, z, force) -> (groundY?, waterY?, isStructure)
	  TPS:GetEndpointGround(geometry, position) -> groundY
	  TPS:NotifyTerrainChanged(minCorner, maxCorner)   (alias InvalidateRegion)
	  TPS:ClearCaches()
	  TPS:BuildDebugPath(geometry, losses) -> table (for developer visualisation)
	  TPS:GetStats() -> table
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("EWShared")
local RFMath = require(Shared.RFMath)
local MaterialProfiles = require(Shared.MaterialProfiles)
local SharedUtilities = require(Shared.SharedUtilities)
local Types = require(Shared.EWTypes)

type PathGeometry = Types.PathGeometry
type PropagationLosses = Types.PropagationLosses
type ObstacleHit = Types.ObstacleHit
type SubPath = Types.SubPath

local TPS = {}

local context
local config
local P -- config.Propagation
local terrain: Terrain = workspace.Terrain

local OFFSET = 524288
local STRIDE = 1048576
local AIR = Enum.Material.Air
local WATER = Enum.Material.Water

-- Height field cache
local heightCache: { [number]: number } = {}
local waterCache: { [number]: number } = {}
local structureCells: { [number]: boolean } = {}
local heightCount = 0
local heightCacheBornAt = os.clock()

-- Region revisions (coarse grid) for path-cache invalidation
local regionRevision: { [number]: number } = {}

-- Path geometry cache
type CacheEntry = { Geometry: PathGeometry, CreatedAt: number, LastUsed: number, Stamp: number }
local pathCache: { [string]: CacheEntry } = {}
local pathCacheCount = 0

-- Classification cache (weak; cleared on maintenance)
local classifyCache = setmetatable({}, { __mode = "k" }) :: { [Instance]: any }

-- Raycast filters
local excludeBase: { Instance } = {}
local vegetationRoots: { Instance } = {}
local filtersDirty = true
local heightParams = RaycastParams.new()
local heightParamsNoWater = RaycastParams.new()
local structParams = RaycastParams.new()
local vegParams = RaycastParams.new()
local includeParams = RaycastParams.new()

local bag = SharedUtilities.ConnectionBag.new()
local pendingInvalidations: { { Min: Vector3, Max: Vector3 } } = {}
local invalidationScheduled = false

local stats = {
	Analyses = 0,
	CacheHits = 0,
	CacheMisses = 0,
	CacheStaleReuse = 0,
	Deferred = 0,
	ProfileOnly = 0,
	HeightProbes = 0,
	HeightRays = 0,
	StructureRays = 0,
	VoxelReads = 0,
	Invalidations = 0,
	AnalysisMsAvg = 0,
	AnalysisMsMax = 0,
	LastAnalysisRays = 0,
}

local VEGETATION_PROFILE = { Key = "Vegetation", Kind = "Vegetation", EntryLossDb = 0, LossDbPerMeter = 0, FrequencyExponent = 0 }

--------------------------------------------------------------------------------
-- Budget helper
--------------------------------------------------------------------------------

type Budget = { Forced: boolean, Rays: number, Voxels: number, Denied: boolean }

local function newBudget(forced: boolean): Budget
	return { Forced = forced, Rays = 0, Voxels = 0, Denied = false }
end

local function useRays(budget: Budget, n: number): boolean
	local scheduler = context.Scheduler
	if budget.Forced then
		scheduler:ConsumeRaycasts(n)
		budget.Rays += n
		return true
	end
	if scheduler:TryConsumeRaycasts(n) then
		budget.Rays += n
		return true
	end
	budget.Denied = true
	return false
end

local function useVoxels(budget: Budget, n: number): boolean
	local scheduler = context.Scheduler
	if budget.Forced then
		scheduler:ConsumeVoxelReads(n)
		budget.Voxels += n
		return true
	end
	if scheduler:TryConsumeVoxelReads(n) then
		budget.Voxels += n
		return true
	end
	budget.Denied = true
	return false
end

--------------------------------------------------------------------------------
-- Filters and part classification
--------------------------------------------------------------------------------

local function markFiltersDirty()
	filtersDirty = true
end

local function rebuildFilters()
	if not filtersDirty then
		return
	end
	filtersDirty = false
	local base = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(base, player.Character)
		end
	end
	for _, inst in ipairs(CollectionService:GetTagged("EWIgnore")) do
		table.insert(base, inst)
	end
	local debugFolder = workspace:FindFirstChild("EWDebug")
	if debugFolder then
		table.insert(base, debugFolder)
	end
	excludeBase = base

	vegetationRoots = CollectionService:GetTagged(P.VegetationTag)

	local heightList = table.clone(base)
	for _, v in ipairs(vegetationRoots) do
		table.insert(heightList, v)
	end
	heightParams.FilterType = Enum.RaycastFilterType.Exclude
	heightParams.FilterDescendantsInstances = heightList
	heightParams.IgnoreWater = false
	heightParams.RespectCanCollide = P.RespectCanCollide
	heightParamsNoWater.FilterType = Enum.RaycastFilterType.Exclude
	heightParamsNoWater.FilterDescendantsInstances = heightList
	heightParamsNoWater.IgnoreWater = true
	heightParamsNoWater.RespectCanCollide = P.RespectCanCollide

	vegParams.FilterType = Enum.RaycastFilterType.Include
	vegParams.FilterDescendantsInstances = vegetationRoots
	vegParams.IgnoreWater = true
	vegParams.RespectCanCollide = false

	structParams.FilterType = Enum.RaycastFilterType.Exclude
	structParams.IgnoreWater = true
	structParams.RespectCanCollide = P.RespectCanCollide

	includeParams.FilterType = Enum.RaycastFilterType.Include
	includeParams.IgnoreWater = true
	includeParams.RespectCanCollide = false

	if P.RaycastCollisionGroup then
		heightParams.CollisionGroup = P.RaycastCollisionGroup
		heightParamsNoWater.CollisionGroup = P.RaycastCollisionGroup
		structParams.CollisionGroup = P.RaycastCollisionGroup
	end
end

local function isIgnoredInstance(part: Instance): boolean
	if part:GetAttribute("EWIgnore") == true or CollectionService:HasTag(part, "EWIgnore") then
		return true
	end
	return false
end

-- Returns the structure material profile for a hit part, or nil if the part is
-- not a significant RF obstacle (decorative, tiny, invisible, character parts).
local function classifyPart(part: BasePart)
	local cached = classifyCache[part]
	if cached ~= nil then
		return cached or nil
	end
	local result = nil
	if part ~= terrain and not isIgnoredInstance(part) then
		local parent = part.Parent
		local override = part:GetAttribute("EWMaterial")
		if override == nil and parent then
			override = parent:GetAttribute("EWMaterial")
		end
		local significant = true
		if override == nil then
			local size = part.Size
			local maxDim = math.max(size.X, size.Y, size.Z)
			if part.Transparency >= P.IgnoreTransparencyAbove then
				significant = false
			elseif maxDim < P.MinObstacleMaxDimension or size.X * size.Y * size.Z < P.MinObstacleVolume then
				significant = false
			elseif parent and (parent:IsA("Accessory") or (parent:IsA("Model") and parent:FindFirstChildOfClass("Humanoid") ~= nil)) then
				significant = false
			end
		end
		if significant then
			if CollectionService:HasTag(part, P.VegetationTag) then
				result = VEGETATION_PROFILE
			else
				local profile = MaterialProfiles.GetStructure(if type(override) == "string" then override else part.Material.Name)
				if profile.Kind ~= "Ignore" then
					result = profile
				end
			end
		end
	end
	classifyCache[part] = result or false
	return result
end

-- Static surface for the height field: terrain or a significant anchored part.
local function isStaticSurface(inst: Instance): boolean
	if inst == terrain then
		return true
	end
	if not inst:IsA("BasePart") then
		return false
	end
	local part = inst :: BasePart
	if not part.Anchored then
		return false
	end
	local profile = classifyPart(part)
	return profile ~= nil and profile.Kind ~= "Vegetation" and profile.Kind ~= "Water"
end

--------------------------------------------------------------------------------
-- Height field
--------------------------------------------------------------------------------

local function cellKey(cx: number, cz: number): number
	return (cx + OFFSET) * STRIDE + (cz + OFFSET)
end

local function coarseKey(x: number, z: number): number
	local cs = P.RegionRevisionCellStuds
	return cellKey(math.floor(x / cs), math.floor(z / cs))
end

local function probeColumn(x: number, z: number): (number, number?, boolean, number)
	local top = P.HeightProbeTop
	local bottom = P.HeightProbeBottom
	local rays = 1
	local result = workspace:Raycast(Vector3.new(x, top, z), Vector3.new(0, bottom - top, 0), heightParams)
	local waterY: number? = nil
	local skips = 0
	while result do
		if result.Material == WATER and waterY == nil then
			waterY = result.Position.Y
			local o = result.Position - Vector3.new(0, 0.05, 0)
			rays += 1
			result = workspace:Raycast(o, Vector3.new(0, bottom - o.Y, 0), heightParamsNoWater)
		elseif not isStaticSurface(result.Instance) and skips < P.MaxSkipHitsPerProbe then
			skips += 1
			local o = result.Position - Vector3.new(0, 0.05, 0)
			rays += 1
			result = workspace:Raycast(o, Vector3.new(0, bottom - o.Y, 0), if waterY then heightParamsNoWater else heightParams)
		else
			break
		end
	end
	if not result then
		return bottom, waterY, false, rays
	end
	return result.Position.Y, waterY, result.Instance ~= terrain, rays
end

-- Ground (top static surface) at a world XZ. Returns nil when not cached and the
-- raycast budget denies a probe (callers degrade gracefully).
function TPS:SampleGround(x: number, z: number, force: boolean?, budget: Budget?): (number?, number?, boolean)
	local cs = P.HeightCellStuds
	local cx, cz = math.floor(x / cs), math.floor(z / cs)
	local key = cellKey(cx, cz)
	local y = heightCache[key]
	if y ~= nil then
		return y, waterCache[key], structureCells[key] == true
	end
	local b = budget or newBudget(force == true)
	-- Reserve two rays (water + ground); extra skip rays are accounted afterwards.
	if not useRays(b, 2) then
		return nil, nil, false
	end
	rebuildFilters()
	local gy, wy, isStructure, rays = probeColumn((cx + 0.5) * cs, (cz + 0.5) * cs)
	if rays > 2 then
		if b.Forced then
			context.Scheduler:ConsumeRaycasts(rays - 2)
		else
			context.Scheduler:TryConsumeRaycasts(rays - 2)
		end
		b.Rays += rays - 2
	end
	stats.HeightProbes += 1
	stats.HeightRays += rays
	heightCache[key] = gy
	if wy then
		waterCache[key] = wy
	end
	if isStructure then
		structureCells[key] = true
	end
	heightCount += 1
	if heightCount > P.MaxHeightCells then
		TPS:ClearCaches()
	end
	return gy, wy, isStructure
end

--------------------------------------------------------------------------------
-- Region revisions / invalidation
--------------------------------------------------------------------------------

local function pathStamp(a: Vector3, b: Vector3): number
	local cs = P.RegionRevisionCellStuds
	local dx, dz = b.X - a.X, b.Z - a.Z
	local length = math.sqrt(dx * dx + dz * dz)
	local steps = math.max(1, math.ceil(length / (cs * 0.5)))
	local sum = 0
	local lastKey = nil
	for i = 0, steps do
		local t = i / steps
		local key = coarseKey(a.X + dx * t, a.Z + dz * t)
		if key ~= lastKey then
			sum += regionRevision[key] or 0
			lastKey = key
		end
	end
	return sum
end

function TPS:InvalidateRegion(minCorner: Vector3, maxCorner: Vector3)
	local lo = Vector3.new(math.min(minCorner.X, maxCorner.X), 0, math.min(minCorner.Z, maxCorner.Z))
	local hi = Vector3.new(math.max(minCorner.X, maxCorner.X), 0, math.max(minCorner.Z, maxCorner.Z))
	stats.Invalidations += 1
	-- Height cells
	local cs = P.HeightCellStuds
	local cx0, cx1 = math.floor(lo.X / cs), math.floor(hi.X / cs)
	local cz0, cz1 = math.floor(lo.Z / cs), math.floor(hi.Z / cs)
	local area = (cx1 - cx0 + 1) * (cz1 - cz0 + 1)
	if area <= heightCount then
		for cx = cx0, cx1 do
			for cz = cz0, cz1 do
				local key = cellKey(cx, cz)
				if heightCache[key] ~= nil then
					heightCache[key] = nil
					waterCache[key] = nil
					structureCells[key] = nil
					heightCount -= 1
				end
			end
		end
	else
		for key in pairs(heightCache) do
			local cx = math.floor(key / STRIDE) - OFFSET
			local cz = (key % STRIDE) - OFFSET
			if cx >= cx0 and cx <= cx1 and cz >= cz0 and cz <= cz1 then
				heightCache[key] = nil
				waterCache[key] = nil
				structureCells[key] = nil
				heightCount -= 1
			end
		end
	end
	-- Region revisions
	local rs = P.RegionRevisionCellStuds
	for rx = math.floor(lo.X / rs), math.floor(hi.X / rs) do
		for rz = math.floor(lo.Z / rs), math.floor(hi.Z / rs) do
			local key = cellKey(rx, rz)
			regionRevision[key] = (regionRevision[key] or 0) + 1
		end
	end
	table.clear(classifyCache)
end

-- Call after scripted terrain edits (Terrain:FillBlock, WriteVoxels, explosions...).
function TPS:NotifyTerrainChanged(minCorner: Vector3, maxCorner: Vector3)
	self:InvalidateRegion(minCorner, maxCorner)
end

function TPS:ClearCaches()
	table.clear(heightCache)
	table.clear(waterCache)
	table.clear(structureCells)
	heightCount = 0
	heightCacheBornAt = os.clock()
	table.clear(pathCache)
	pathCacheCount = 0
	table.clear(classifyCache)
	-- Bump everything: any stale geometry still referenced elsewhere is invalid.
	for key, rev in pairs(regionRevision) do
		regionRevision[key] = rev + 1
	end
end

local function queuePartInvalidation(part: BasePart)
	local size = part.Size
	if math.max(size.X, size.Y, size.Z) < P.AutoInvalidateMinPartSize then
		return
	end
	local cf = part.CFrame
	local half = size / 2
	-- Conservative axis-aligned bounds of the rotated part.
	local r = math.abs(cf.RightVector.X) * half.X + math.abs(cf.UpVector.X) * half.Y + math.abs(cf.LookVector.X) * half.Z
	local f = math.abs(cf.RightVector.Z) * half.X + math.abs(cf.UpVector.Z) * half.Y + math.abs(cf.LookVector.Z) * half.Z
	local p = cf.Position
	table.insert(pendingInvalidations, { Min = Vector3.new(p.X - r, 0, p.Z - f), Max = Vector3.new(p.X + r, 0, p.Z + f) })
	if not invalidationScheduled then
		invalidationScheduled = true
		task.defer(function()
			invalidationScheduled = false
			local list = pendingInvalidations
			pendingInvalidations = {}
			for _, box in ipairs(list) do
				TPS:InvalidateRegion(box.Min, box.Max)
			end
		end)
	end
end

--------------------------------------------------------------------------------
-- Ray tracing helpers
--------------------------------------------------------------------------------

local function castLong(origin: Vector3, unit: Vector3, length: number, params: RaycastParams, budget: Budget): (RaycastResult?, number, boolean)
	-- Splits long rays into segments; returns (result, distanceFromOrigin, budgetOk).
	local segment = config.Units.MaxRaySegmentStuds
	local travelled = 0
	while travelled < length do
		if not useRays(budget, 1) then
			return nil, travelled, false
		end
		local step = math.min(segment, length - travelled)
		local result = workspace:Raycast(origin + unit * travelled, unit * step, params)
		stats.StructureRays += 1
		if result then
			return result, travelled + result.Distance, true
		end
		travelled += step
	end
	return nil, length, true
end

local function isConvexPart(part: BasePart): boolean
	return part:IsA("Part") or part:IsA("WedgePart") or part:IsA("CornerWedgePart") or part:IsA("TrussPart")
end

-- Distance (along the ray) at which the ray leaves the solid piece of `part` it entered at hitDist.
local function findExit(part: BasePart, origin: Vector3, unit: Vector3, hitDist: number, total: number, budget: Budget): (number, boolean)
	local probeLen = math.min(total - hitDist, part.Size.Magnitude + 0.5)
	if probeLen <= 0.02 then
		return hitDist, false
	end
	includeParams.FilterDescendantsInstances = { part }
	local farDist = hitDist + probeLen
	if not isConvexPart(part) then
		-- MeshParts / Unions may contain cavities: find the next entry into the same part.
		if useRays(budget, 1) then
			stats.StructureRays += 1
			local fwd = workspace:Raycast(origin + unit * (hitDist + 0.02), unit * (probeLen - 0.02), includeParams)
			if fwd then
				farDist = hitDist + 0.02 + fwd.Distance
			end
		end
	end
	if not useRays(budget, 1) then
		return math.min(hitDist + 1, total), true
	end
	stats.StructureRays += 1
	local back = workspace:Raycast(origin + unit * farDist, -unit * (farDist - hitDist), includeParams)
	local exitDist = farDist
	if back then
		exitDist = farDist - back.Distance
	end
	if exitDist < hitDist then
		exitDist = hitDist
	end
	return exitDist, (exitDist - hitDist) > P.MaxPenetrationStudsPerObstacle
end

-- Traces significant obstacles between origin and target.
-- mode "Structure": all significant parts (vegetation-material parts add vegetation depth)
-- mode "Vegetation": every hit is vegetation (include-filtered foliage)
local function traceObstacles(
	origin: Vector3,
	target: Vector3,
	params: RaycastParams,
	mode: string,
	distanceOffset: number,
	budget: Budget
): ({ ObstacleHit }, number, boolean, boolean)
	local obstacles: { ObstacleHit } = {}
	local vegetation = 0
	local delta = target - origin
	local total = delta.Magnitude
	if total < 0.05 then
		return obstacles, vegetation, true, false
	end
	local unit = delta / total
	local travelled = 0
	local guard = 0
	local truncated = false
	while travelled < total - 0.05 do
		guard += 1
		if guard > P.MaxObstaclesPerRay * 3 then
			truncated = true
			break
		end
		local result, hitAt, ok = castLong(origin + unit * travelled, unit, total - travelled, params, budget)
		if not ok then
			return obstacles, vegetation, false, truncated
		end
		if not result then
			break
		end
		local hitDist = travelled + hitAt
		local part = result.Instance :: BasePart
		local profile
		if mode == "Vegetation" then
			profile = VEGETATION_PROFILE
		else
			profile = classifyPart(part)
		end
		if not profile then
			-- Insignificant part: continue from just inside it (rays starting inside
			-- a part never hit that part again).
			travelled = hitDist + 0.02
			continue
		end
		local exitDist, capped = findExit(part, origin, unit, hitDist, total, budget)
		local thickness = exitDist - hitDist
		if profile.Kind == "Vegetation" then
			vegetation += thickness
		else
			local fixed = part:GetAttribute("EWAttenuationDb")
			table.insert(obstacles, {
				Instance = part,
				MaterialKey = profile.Key,
				Kind = profile.Kind,
				DistanceFromAStuds = distanceOffset + hitDist,
				ThicknessStuds = thickness,
				EntryPosition = origin + unit * hitDist,
				ExitPosition = origin + unit * exitDist,
				Capped = capped,
				FixedLossDb = if type(fixed) == "number" then fixed else nil,
			} :: any)
			if #obstacles >= P.MaxObstaclesPerRay then
				truncated = true
				break
			end
		end
		travelled = exitDist + 0.02
	end
	return obstacles, vegetation, true, truncated
end

local function readVoxel(position: Vector3): (Enum.Material, number)
	local base = Vector3.new(math.floor(position.X / 4) * 4, math.floor(position.Y / 4) * 4, math.floor(position.Z / 4) * 4)
	local materials, occupancies = terrain:ReadVoxels(Region3.new(base, base + Vector3.new(4, 4, 4)), 4)
	stats.VoxelReads += 1
	return materials[1][1][1], occupancies[1][1][1]
end

--------------------------------------------------------------------------------
-- Path analysis
--------------------------------------------------------------------------------

local function quantKey(p: Vector3): string
	local q = P.PathQuantumStuds
	return string.format("%d,%d,%d", math.floor(p.X / q + 0.5), math.floor(p.Y / q + 0.5), math.floor(p.Z / q + 0.5))
end

local function emptyGeometry(a: Vector3, b: Vector3, mode): PathGeometry
	return {
		A = a,
		B = b,
		DistanceStuds = (b - a).Magnitude,
		HorizontalStuds = Vector2.new(b.X - a.X, b.Z - a.Z).Magnitude,
		SampleCount = 0,
		SampleSpacingStuds = 0,
		SampleDistances = {},
		SampleGround = {},
		SampleLos = {},
		SampleKind = {},
		SampleExcluded = {},
		GroundA = a.Y - 1,
		GroundB = b.Y - 1,
		MeanInteriorGround = math.min(a.Y, b.Y) - 1,
		TerrainSolidStuds = 0,
		TerrainSolidMaterials = {},
		WaterPathStuds = 0,
		CavityStuds = 0,
		EndpointWaterDepthA = 0,
		EndpointWaterDepthB = 0,
		SubPaths = {},
		EndpointClutterRadiusStuds = P.EndpointClutterRadiusStuds,
		Mode = mode,
		RaycastsUsed = 0,
		VoxelReadsUsed = 0,
		ComputedAt = os.clock(),
		Approximate = false,
		Notes = {},
	}
end

-- Floor under an endpoint that sits beneath a roof, overhang or water surface.
local function floorBelow(position: Vector3, budget: Budget): number?
	if not useRays(budget, 1) then
		return nil
	end
	local origin = position
	local direction = Vector3.new(0, math.max(P.HeightProbeBottom - position.Y, -config.Units.MaxRaySegmentStuds), 0)
	if direction.Y >= 0 then
		return nil
	end
	local result = workspace:Raycast(origin, direction, heightParamsNoWater)
	local skips = 0
	while result and not isStaticSurface(result.Instance) and skips < P.MaxSkipHitsPerProbe do
		skips += 1
		if not useRays(budget, 1) then
			return nil
		end
		local o = result.Position - Vector3.new(0, 0.05, 0)
		result = workspace:Raycast(o, Vector3.new(0, math.max(P.HeightProbeBottom - o.Y, -config.Units.MaxRaySegmentStuds), 0), heightParamsNoWater)
	end
	return if result then result.Position.Y else nil
end

local function endpointWaterDepth(position: Vector3, waterY: number?, budget: Budget): number
	if waterY == nil or position.Y >= waterY then
		return 0
	end
	if useVoxels(budget, 1) then
		local material, occupancy = readVoxel(position)
		if material ~= WATER or occupancy < 0.5 then
			return 0 -- air pocket / submerged structure interior
		end
	end
	return waterY - position.Y
end

local function analyze(a: Vector3, b: Vector3, options, budget: Budget, previous: PathGeometry?): PathGeometry
	rebuildFilters()
	local profile = context.Scheduler:GetProfile()
	local geometry = emptyGeometry(a, b, "Full")
	local notes = geometry.Notes
	local D = geometry.DistanceStuds
	local H = geometry.HorizontalStuds
	if D < 0.05 then
		return geometry
	end

	------------------------------------------------------------------ endpoints
	local gA, wA = TPS:SampleGround(a.X, a.Z, budget.Forced, budget)
	local gB, wB = TPS:SampleGround(b.X, b.Z, budget.Forced, budget)
	-- A water surface is the reflecting "ground" for antennas above it.
	geometry.GroundA = if gA then math.max(gA, wA or -math.huge) else (a.Y - 1)
	geometry.GroundB = if gB then math.max(gB, wB or -math.huge) else (b.Y - 1)
	geometry.EndpointWaterDepthA = endpointWaterDepth(a, wA, budget)
	geometry.EndpointWaterDepthB = endpointWaterDepth(b, wB, budget)
	-- Indoors / under cover / submerged: the reflecting ground is the floor below.
	if geometry.GroundA > a.Y then
		geometry.GroundA = floorBelow(a, budget) or (a.Y - 1.5)
	end
	if geometry.GroundB > b.Y then
		geometry.GroundB = floorBelow(b, budget) or (b.Y - 1.5)
	end

	------------------------------------------------------------------ profile
	local maxSamples = math.min(P.ProfileMaxSamples, profile.ProfileMaxSamples)
	local n = 0
	if H >= 1 then
		n = math.clamp(math.floor(H / P.ProfileSpacingStuds), P.ProfileMinSamples, maxSamples)
	end
	local samples = {}
	local missing = 0
	for i = 1, n do
		local t = i / (n + 1)
		local p = a:Lerp(b, t)
		local g, w, isStructure = TPS:SampleGround(p.X, p.Z, budget.Forced, budget)
		if g == nil then
			missing += 1
		elseif w and w > g then
			-- Water surface is the profile surface; LOS below it is checked voxel-wise.
			g = w
		end
		table.insert(samples, { t = t, d = t * D, ground = g, water = w, structure = isStructure, los = p.Y, extra = false })
	end
	if n > 0 and missing > 0 then
		if missing > n * 0.5 then
			geometry.Mode = "Deferred"
			stats.Deferred += 1
			return geometry
		end
		-- Fill gaps by interpolating cached neighbours (marked approximate).
		geometry.Approximate = true
		table.insert(notes, string.format("%d/%d profile cells interpolated (raycast budget)", missing, n))
		for i, s in ipairs(samples) do
			if s.ground == nil then
				local before, after
				for j = i - 1, 1, -1 do
					if samples[j].ground ~= nil then
						before = samples[j]
						break
					end
				end
				for j = i + 1, n do
					if samples[j].ground ~= nil then
						after = samples[j]
						break
					end
				end
				if before and after then
					s.ground = before.ground + (after.ground - before.ground) * ((s.t - before.t) / (after.t - before.t))
				else
					s.ground = (before and before.ground) or (after and after.ground) or math.min(geometry.GroundA, geometry.GroundB)
				end
			end
		end
	end

	------------------------------------------------------------------ structures
	local exclude = table.clone(excludeBase)
	table.insert(exclude, terrain)
	for _, v in ipairs(vegetationRoots) do
		table.insert(exclude, v)
	end
	if options.ExcludeInstances then
		for _, inst in ipairs(options.ExcludeInstances) do
			table.insert(exclude, inst)
		end
	end
	structParams.FilterDescendantsInstances = exclude

	local subPaths: { SubPath } = {}
	local structureOk = true
	local centerObstacles, centerVeg, ok, truncated = traceObstacles(a, b, structParams, "Structure", 0, budget)
	if not ok then
		structureOk = false
	end
	if truncated then
		table.insert(notes, "Obstacle limit reached on center ray (remaining structure treated as one opaque obstacle)")
		table.insert(centerObstacles, {
			Instance = nil,
			MaterialKey = "Default",
			Kind = "Opaque",
			DistanceFromAStuds = D * 0.5,
			ThicknessStuds = P.MaxPenetrationStudsPerObstacle,
			EntryPosition = a:Lerp(b, 0.5),
			ExitPosition = a:Lerp(b, 0.5),
			Capped = true,
		} :: any)
	end
	-- Tagged foliage along the center ray.
	if #vegetationRoots > 0 and structureOk then
		local _, vegLength, vegOk = traceObstacles(a, b, vegParams, "Vegetation", 0, budget)
		if vegOk then
			centerVeg += vegLength
		else
			geometry.Approximate = true
		end
	end
	if structureOk then
		table.insert(subPaths, { Obstacles = centerObstacles, VegetationStuds = centerVeg, Weight = 2, OffsetStuds = 0 })
	end

	-- Fresnel spindle sub-paths.
	local spindles = options.SpindleSubPaths
	if spindles == nil then
		spindles = math.min(P.SpindleSubPaths, profile.SpindleSubPaths)
		if P.SpindleOnlyWhenObstructed and (options.Priority or 2) > 1 and #centerObstacles == 0 then
			spindles = 0
		end
	end
	if structureOk and spindles > 0 and D > 4 then
		local mps = config.Units.MetersPerStud
		local lambda = RFMath.WavelengthMeters(P.SpindleReferenceMHz)
		local half = D * mps / 2
		local radiusStuds = math.min(RFMath.FresnelRadiusMeters(half, half, lambda) * P.SpindleFresnelFraction / mps, P.SpindleMaxOffsetStuds)
		if radiusStuds > 0.5 then
			local dir = (b - a).Unit
			local u = dir:Cross(Vector3.yAxis)
			if u.Magnitude < 1e-3 then
				u = Vector3.xAxis
			end
			u = u.Unit
			local w = u:Cross(dir).Unit
			local offsets = { u, -u, w, -w }
			local mid = a:Lerp(b, 0.5)
			for j = 1, math.min(spindles, 4) do
				local m = mid + offsets[j] * radiusStuds
				local first, vegA, okA = traceObstacles(a, m, structParams, "Structure", 0, budget)
				if not okA then
					geometry.Approximate = true
					break
				end
				local second, vegB, okB = traceObstacles(m, b, structParams, "Structure", (m - a).Magnitude, budget)
				if not okB then
					geometry.Approximate = true
					break
				end
				for _, o in ipairs(second) do
					table.insert(first, o)
				end
				table.insert(subPaths, { Obstacles = first, VegetationStuds = vegA + vegB, Weight = 1, OffsetStuds = radiusStuds })
			end
		end
	end

	if not structureOk then
		if previous and #previous.SubPaths > 0 then
			subPaths = previous.SubPaths
			table.insert(notes, "Structure data reused from previous analysis (raycast budget)")
		else
			geometry.Mode = "ProfileOnly"
			stats.ProfileOnly += 1
			table.insert(notes, "Structure tracing skipped (raycast budget) - terrain only")
		end
		geometry.Approximate = true
	end
	geometry.SubPaths = subPaths

	-- Obstacles on the center ray become explicit diffraction-profile points so a
	-- thin tall wall between two profile samples is never missed.
	if structureOk then
		for _, o in ipairs(centerObstacles) do
			local part = o.Instance
			if part and part:IsA("BasePart") then
				local cf, size = part.CFrame, part.Size
				local half = size / 2
				-- Top of the part's world bounding box (exact for walls, vehicles, crates).
				local aabbTop = cf.Position.Y
					+ math.abs(cf.RightVector.Y) * half.X
					+ math.abs(cf.UpVector.Y) * half.Y
					+ math.abs(cf.LookVector.Y) * half.Z
				local huge = part.Anchored and math.max(size.X, size.Y, size.Z) > 200
				for _, pos in ipairs({ o.EntryPosition, o.ExitPosition }) do
					local top: number = aabbTop
					local w: number? = nil
					if huge then
						-- Very large static meshes (rock formations): the bounding box would
						-- exaggerate, so use the real cached surface height at this point.
						local g, wy = TPS:SampleGround(pos.X, pos.Z, budget.Forced, budget)
						if g then
							top, w = g, wy
						end
					end
					local t = math.clamp((pos - a):Dot(b - a) / (D * D), 0, 1)
					table.insert(samples, { t = t, d = t * D, ground = top, water = w, structure = true, los = a.Y + (b.Y - a.Y) * t, extra = true })
				end
			end
		end
		table.sort(samples, function(x, y)
			return x.d < y.d
		end)
	end

	------------------------------------------------------------------ profile arrays
	local count = #samples
	local spacing = if n > 0 then D / (n + 1) else 0
	local clutterR = P.EndpointClutterRadiusStuds
	local groundExcl = P.EndpointGroundExclusionStuds
	local sumGround, sumCount = 0, 0
	local solidStuds = 0
	local solidMaterials = {}
	local waterStuds = 0
	local cavityStuds = 0
	local voxelChecks = 0
	for i, s in ipairs(samples) do
		geometry.SampleDistances[i] = s.d
		geometry.SampleGround[i] = s.ground
		geometry.SampleLos[i] = s.los
		geometry.SampleKind[i] = if s.structure then 1 else 0
		local fromA, fromB = s.d, D - s.d
		local excluded = fromA < groundExcl or fromB < groundExcl or (s.structure and (fromA < clutterR or fromB < clutterR))
		geometry.SampleExcluded[i] = excluded
		if not excluded and not (s.los < s.ground and s.structure) then
			sumGround += s.ground
			sumCount += 1
		end
		-- Terrain mass / water under the line of sight (regular samples only).
		if not s.extra and spacing > 0 then
			if s.los < s.ground then
				local solid = not s.structure
				local materialName = "Default"
				if voxelChecks < P.MaxVoxelReadsPerPath and useVoxels(budget, 1) then
					voxelChecks += 1
					local p = a:Lerp(b, s.t)
					local material, occupancy = readVoxel(p)
					if material == WATER and occupancy > 0.5 then
						solid = false
						waterStuds += spacing
					elseif material ~= AIR and occupancy > 0.5 then
						solid = true
						materialName = material.Name
					else
						-- Open space under the surface: the line of sight is NOT blocked
						-- here, so the covering surface must not act as a diffraction edge.
						solid = false
						geometry.SampleExcluded[i] = true
						if not s.structure then
							cavityStuds += spacing -- tunnel / cave / bunker (terrain-covered)
						end
					end
				elseif voxelChecks >= P.MaxVoxelReadsPerPath then
					geometry.Approximate = true
				end
				if solid then
					solidStuds += spacing
					solidMaterials[materialName] = (solidMaterials[materialName] or 0) + spacing
				end
			elseif s.water and s.los < s.water then
				waterStuds += spacing
			end
		end
	end
	geometry.SampleCount = count
	geometry.SampleSpacingStuds = spacing
	geometry.MeanInteriorGround = if sumCount > 0 then sumGround / sumCount else math.min(geometry.GroundA, geometry.GroundB)
	geometry.TerrainSolidStuds = solidStuds
	geometry.TerrainSolidMaterials = solidMaterials
	geometry.WaterPathStuds = waterStuds
	geometry.CavityStuds = cavityStuds
	geometry.RaycastsUsed = budget.Rays
	geometry.VoxelReadsUsed = budget.Voxels
	geometry.ComputedAt = os.clock()
	return geometry
end

local function evictIfNeeded()
	if pathCacheCount <= P.PathCacheMaxEntries then
		return
	end
	local cutoff = os.clock() - P.PathCacheTtlSeconds * 0.5
	for key, entry in pairs(pathCache) do
		if entry.LastUsed < cutoff then
			pathCache[key] = nil
			pathCacheCount -= 1
		end
	end
	if pathCacheCount > P.PathCacheMaxEntries * 0.9 then
		table.clear(pathCache)
		pathCacheCount = 0
	end
end

function TPS:AnalyzePath(a: Vector3, b: Vector3, options): PathGeometry?
	options = options or {}
	local t0 = os.clock()
	local ka, kb = quantKey(a), quantKey(b)
	local key, first, second
	if ka <= kb then
		key, first, second = ka .. "|" .. kb, a, b
	else
		key, first, second = kb .. "|" .. ka, b, a
	end
	local now = os.clock()
	local entry = pathCache[key]
	local previous: PathGeometry? = entry and entry.Geometry or nil
	if entry and not options.NoCache then
		local fresh = (now - entry.CreatedAt) <= P.PathCacheTtlSeconds and entry.Stamp == pathStamp(first, second)
		if fresh then
			entry.LastUsed = now
			stats.CacheHits += 1
			return entry.Geometry
		end
	end
	stats.CacheMisses += 1

	local forced = options.Force == true
	-- Not enough budget for a meaningful analysis: reuse stale data if we have it.
	if not forced and context.Scheduler:RemainingRaycasts() < 4 then
		if previous then
			stats.CacheStaleReuse += 1
			return previous
		end
		stats.Deferred += 1
		return nil
	end

	local budget = newBudget(forced)
	local geometry = analyze(first, second, options, budget, previous)
	stats.Analyses += 1
	stats.LastAnalysisRays = budget.Rays
	local ms = (os.clock() - t0) * 1000
	stats.AnalysisMsAvg = stats.AnalysisMsAvg * 0.95 + ms * 0.05
	if ms > stats.AnalysisMsMax then
		stats.AnalysisMsMax = ms
	end
	if geometry.Mode == "Deferred" then
		if previous then
			stats.CacheStaleReuse += 1
			return previous
		end
		return nil
	end
	if not options.NoCache then
		if not pathCache[key] then
			pathCacheCount += 1
		end
		pathCache[key] = { Geometry = geometry, CreatedAt = now, LastUsed = now, Stamp = pathStamp(first, second) }
		evictIfNeeded()
	end
	return geometry
end

--------------------------------------------------------------------------------
-- Frequency-dependent losses
--------------------------------------------------------------------------------

local function waterLossPerMeter(frequencyMHz: number): number
	return P.WaterLossDbPerMeterAt100MHz * (math.max(frequencyMHz, 1) / 100) ^ P.WaterFrequencyExponent
end

local function obstacleLossDb(o, frequencyMHz: number, mps: number): number
	if o.FixedLossDb then
		return o.FixedLossDb
	end
	if o.Kind == "Opaque" or o.Capped then
		return MaterialProfiles.OpaqueLossDb
	end
	local profile = MaterialProfiles.GetStructure(o.MaterialKey)
	return MaterialProfiles.StructureLossDb(profile, o.ThicknessStuds * mps, frequencyMHz)
end

local scratchD = {}
local scratchH = {}
local scratchFlat = {}

function TPS:ComputeLosses(geometry: PathGeometry, frequencyMHz: number): PropagationLosses
	local mps = config.Units.MetersPerStud
	local lambda = RFMath.WavelengthMeters(frequencyMHz)
	local Dm = geometry.DistanceStuds * mps
	local explanation = {}

	------------------------------------------------------------------ diffraction
	-- The plane-earth basic loss already accounts for a smooth ground plane, so
	-- diffraction is reported as the EXCESS of the real profile over a smooth
	-- baseline profile (straight line between the ground under each terminal).
	-- Flat ground therefore adds 0 dB here; ridges, hills and buildings add loss.
	local n = geometry.SampleCount
	local k = P.EarthKFactor
	local baseA = if geometry.GroundA > geometry.A.Y then geometry.A.Y - 1.5 else geometry.GroundA
	local baseB = if geometry.GroundB > geometry.B.Y then geometry.B.Y - 1.5 else geometry.GroundB
	local Ds0 = math.max(geometry.DistanceStuds, 1e-6)
	for i = 1, n do
		local dStuds = geometry.SampleDistances[i]
		local d = dStuds * mps
		local bulge = RFMath.EarthBulgeMeters(d, Dm - d, k)
		scratchD[i] = d
		scratchH[i] = geometry.SampleGround[i] * mps + bulge
		scratchFlat[i] = (baseA + (baseB - baseA) * (dStuds / Ds0)) * mps + bulge
	end
	local deygout = RFMath.DeygoutLossDb(
		scratchD,
		scratchH,
		geometry.SampleExcluded,
		n,
		geometry.A.Y * mps,
		geometry.B.Y * mps,
		Dm,
		lambda,
		P.MaxDiffractionDepth
	)
	local smooth = RFMath.DeygoutLossDb(
		scratchD,
		scratchFlat,
		geometry.SampleExcluded,
		n,
		geometry.A.Y * mps,
		geometry.B.Y * mps,
		Dm,
		lambda,
		P.MaxDiffractionDepth
	)
	local diffraction = math.max(0, deygout.LossDb - smooth.LossDb)
	local principalDistance, principalHeight = nil, nil
	if deygout.PrincipalIndex then
		local i = deygout.PrincipalIndex
		principalDistance = geometry.SampleDistances[i]
		principalHeight = geometry.SampleGround[i] - geometry.SampleLos[i]
		if diffraction > 0.5 then
			table.insert(
				explanation,
				string.format(
					"%s edge %.0f studs from A rises %.1f studs %s the line of sight (v=%.2f): %.1f dB diffraction over %d edge(s)",
					if geometry.SampleKind[i] == 1 then "Structure" else "Terrain",
					principalDistance,
					math.abs(principalHeight),
					if principalHeight >= 0 then "above" else "below",
					deygout.PrincipalV,
					diffraction,
					deygout.Edges
				)
			)
		end
	end

	------------------------------------------------------------------ terrain mass
	local terrainDb = 0
	for materialName, studs in pairs(geometry.TerrainSolidMaterials) do
		local profile = MaterialProfiles.GetTerrain(materialName)
		terrainDb += studs * mps * MaterialProfiles.TerrainLossDbPerMeter(profile, frequencyMHz)
	end
	terrainDb = math.min(terrainDb, P.TerrainPenetrationMaxDb)
	if geometry.TerrainSolidStuds > 0 then
		table.insert(explanation, string.format("Line of sight passes through %.0f studs of solid terrain: %.1f dB if penetrated", geometry.TerrainSolidStuds, terrainDb))
	end

	------------------------------------------------------------------ water
	local wpm = waterLossPerMeter(frequencyMHz)
	local endpointWaterDb = 0
	for _, depth in ipairs({ geometry.EndpointWaterDepthA, geometry.EndpointWaterDepthB }) do
		if depth > 0 then
			endpointWaterDb += P.WaterInterfaceLossDb + depth * mps * wpm
		end
	end
	endpointWaterDb = math.min(endpointWaterDb, P.WaterMaxLossDb)
	if endpointWaterDb > 0 then
		table.insert(explanation, string.format("Submerged endpoint(s): %.1f dB water loss", endpointWaterDb))
	end
	local pathWaterDb = 0
	if geometry.WaterPathStuds > 0 then
		pathWaterDb = math.min(P.WaterInterfaceLossDb + geometry.WaterPathStuds * mps * wpm, P.WaterMaxLossDb)
		table.insert(explanation, string.format("Line of sight crosses %.0f studs of water: %.1f dB", geometry.WaterPathStuds, pathWaterDb))
	end

	------------------------------------------------------------------ cavities (tunnels / caves)
	local cavityDb = 0
	if geometry.CavityStuds > 0 then
		local perMeter = P.CavityLossDbPerMeterAt300MHz * (math.max(frequencyMHz, 1) / 300) ^ P.CavityFrequencyExponent
		cavityDb = math.min(geometry.CavityStuds * mps * perMeter, P.CavityMaxLossDb)
		table.insert(explanation, string.format("Line of sight runs %.0f studs through terrain-covered open space (tunnel/cave): %.1f dB", geometry.CavityStuds, cavityDb))
	end

	------------------------------------------------------------------ structures + vegetation
	local subLosses = {}
	local subWeights = {}
	local centerDb, clutterDb, vegetationDb = 0, 0, 0
	local clutterR = geometry.EndpointClutterRadiusStuds
	local Ds = geometry.DistanceStuds
	local fGHz = frequencyMHz / 1000
	for index, sub in ipairs(geometry.SubPaths) do
		local total = 0
		for _, o in ipairs(sub.Obstacles) do
			local l = obstacleLossDb(o, frequencyMHz, mps)
			total += l
			if index == 1 and (o.DistanceFromAStuds <= clutterR or o.DistanceFromAStuds >= Ds - clutterR) then
				clutterDb += l
			end
		end
		if index == 1 then
			centerDb = total
			-- Foliage is a volume loss along the direct path (Weissberger); it is not
			-- averaged over the spindle paths, which only probe structure edges.
			vegetationDb = math.min(RFMath.WeissbergerLossDb(sub.VegetationStuds * mps, fGHz, P.VegetationMinFrequencyGHz), P.VegetationMaxLossDb)
		end
		table.insert(subLosses, math.min(total, MaterialProfiles.OpaqueLossDb * 2))
		table.insert(subWeights, sub.Weight)
	end
	local structureDb = if #subLosses > 0 then RFMath.PowerAverageLossDb(subLosses, subWeights) else 0
	local center = geometry.SubPaths[1]
	if center and #center.Obstacles > 0 then
		local parts = {}
		for i, o in ipairs(center.Obstacles) do
			if i > 4 then
				table.insert(parts, string.format("+%d more", #center.Obstacles - 4))
				break
			end
			table.insert(parts, string.format("%s %.1f studs (%.1f dB)", o.MaterialKey, o.ThicknessStuds, obstacleLossDb(o, frequencyMHz, mps)))
		end
		table.insert(explanation, string.format("Direct ray penetrates %d obstacle(s): %s", #center.Obstacles, table.concat(parts, ", ")))
	end
	if #geometry.SubPaths > 1 then
		table.insert(explanation, string.format("Fresnel-zone sampling (%d paths): effective structure loss %.1f dB (center %.1f dB)", #geometry.SubPaths, structureDb, centerDb))
	end
	if vegetationDb > 0.1 and center then
		table.insert(explanation, string.format("Vegetation depth %.0f studs: %.1f dB", center.VegetationStuds, vegetationDb))
	end
	if clutterDb > 0 then
		table.insert(explanation, string.format("Obstacles within %d studs of an endpoint (must be passed on any path): %.1f dB", clutterR, clutterDb))
	end

	------------------------------------------------------------------ combine paths
	-- When the direct ray is clear, J(v) already describes the whole terrain
	-- effect (Fresnel-zone intrusion) and there is no separate "through" path.
	-- When the direct ray is blocked, the signal can either be diffracted over
	-- the obstruction or penetrate it; the two are combined as incoherent
	-- alternative paths. Without a real diffraction edge both "paths" would be
	-- the same physical path, so the smaller one is used instead of a power sum.
	local directBlocked = geometry.TerrainSolidStuds > 0 or geometry.WaterPathStuds > 0 or (center ~= nil and #center.Obstacles > 0)
	local overTop = diffraction + clutterDb + endpointWaterDb + cavityDb
	local through = terrainDb + structureDb + vegetationDb + pathWaterDb + endpointWaterDb + cavityDb
	local excess, dominant
	if not directBlocked then
		excess = diffraction + structureDb + vegetationDb + endpointWaterDb + cavityDb
		overTop = excess
		through = excess
		dominant = "Direct"
	elseif diffraction > 0.5 then
		excess = RFMath.ParallelLossDb(overTop, through)
		if math.abs(overTop - through) < 3 then
			dominant = "Mixed"
		elseif overTop < through then
			dominant = "OverTheTop"
		else
			dominant = "Through"
		end
	else
		excess = math.min(overTop, through)
		dominant = if overTop < through then "OverTheTop" else "Through"
	end
	if excess < 0 then
		excess = 0
	end

	local lineOfSight = deygout.PrincipalV < 0 and geometry.TerrainSolidStuds == 0 and (center == nil or #center.Obstacles == 0) and geometry.WaterPathStuds == 0
	local class
	if lineOfSight and excess < P.PartialObstructionMinDb then
		class = "Unobstructed"
	elseif lineOfSight and excess < P.ObstructedMinDb then
		class = "PartiallyObstructed"
	elseif excess < P.PartialObstructionMinDb then
		class = "PartiallyObstructed"
	elseif excess < P.HeavyObstructionMinDb then
		class = "Obstructed"
	else
		class = "HeavilyObstructed"
	end
	if lineOfSight and diffraction > 0 then
		table.insert(explanation, string.format("Line of sight is clear but terrain intrudes into the Fresnel zone (v=%.2f)", deygout.PrincipalV))
	end
	table.insert(
		explanation,
		string.format("Over-the-top path %.1f dB vs through path %.1f dB -> excess %.1f dB (%s, %s)", overTop, through, excess, dominant, class)
	)
	if geometry.Approximate then
		table.insert(explanation, "Approximate: " .. table.concat(geometry.Notes, "; "))
	end

	return {
		FrequencyMHz = frequencyMHz,
		DiffractionDb = diffraction,
		DiffractionEdges = deygout.Edges,
		PrincipalV = deygout.PrincipalV,
		PrincipalEdgeDistanceStuds = principalDistance,
		PrincipalEdgeHeightStuds = principalHeight,
		TerrainPenetrationDb = terrainDb,
		StructureDb = structureDb,
		StructureCenterDb = centerDb,
		EndpointClutterDb = clutterDb,
		VegetationDb = vegetationDb,
		WaterDb = pathWaterDb + endpointWaterDb,
		CavityDb = cavityDb,
		OverTheTopDb = overTop,
		ThroughPathDb = through,
		ExcessDb = excess,
		DominantPath = dominant,
		Class = class,
		LineOfSight = lineOfSight,
		Explanation = explanation,
	}
end

function TPS:GetEndpointGround(geometry: PathGeometry, position: Vector3): number
	if (position - geometry.A).Magnitude <= (position - geometry.B).Magnitude then
		return geometry.GroundA
	end
	return geometry.GroundB
end

-- Serializable path description for the developer debug renderer.
function TPS:BuildDebugPath(geometry: PathGeometry, losses: PropagationLosses?)
	local obstacles = {}
	for subIndex, sub in ipairs(geometry.SubPaths) do
		for _, o in ipairs(sub.Obstacles) do
			table.insert(obstacles, { Entry = o.EntryPosition, Exit = o.ExitPosition, Material = o.MaterialKey, Center = subIndex == 1 })
		end
	end
	local edge = nil
	if losses and losses.PrincipalEdgeDistanceStuds then
		local t = losses.PrincipalEdgeDistanceStuds / math.max(geometry.DistanceStuds, 1e-6)
		local p = geometry.A:Lerp(geometry.B, t)
		edge = Vector3.new(p.X, p.Y + (losses.PrincipalEdgeHeightStuds or 0), p.Z)
	end
	return {
		A = geometry.A,
		B = geometry.B,
		Class = losses and losses.Class or "Unobstructed",
		ExcessDb = losses and losses.ExcessDb or 0,
		Obstacles = obstacles,
		Edge = edge,
	}
end

function TPS:GetStats()
	local out = table.clone(stats)
	out.HeightCells = heightCount
	out.PathCacheEntries = pathCacheCount
	out.HeightCacheAgeSeconds = os.clock() - heightCacheBornAt
	local hits, misses = stats.CacheHits, stats.CacheMisses
	out.CacheHitRate = if hits + misses > 0 then hits / (hits + misses) else 0
	return out
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function TPS:Init(ctx)
	context = ctx
	config = ctx.Config
	P = config.Propagation
	P.HeightCacheMaxAgeSeconds = P.HeightCacheMaxAgeSeconds or 300
end

function TPS:Start()
	local function onCharacter()
		markFiltersDirty()
	end
	local function hookPlayer(player: Player)
		bag:Add(player.CharacterAdded:Connect(onCharacter))
		bag:Add(player.CharacterRemoving:Connect(onCharacter))
	end
	bag:Add(Players.PlayerAdded:Connect(function(player)
		hookPlayer(player)
		markFiltersDirty()
	end))
	bag:Add(Players.PlayerRemoving:Connect(markFiltersDirty))
	for _, player in ipairs(Players:GetPlayers()) do
		hookPlayer(player)
	end
	for _, tag in ipairs({ "EWIgnore", P.VegetationTag }) do
		bag:Add(CollectionService:GetInstanceAddedSignal(tag):Connect(function()
			markFiltersDirty()
			table.clear(classifyCache)
		end))
		bag:Add(CollectionService:GetInstanceRemovedSignal(tag):Connect(function()
			markFiltersDirty()
			table.clear(classifyCache)
		end))
	end
	-- Large anchored parts appearing/disappearing (buildings spawned, walls destroyed).
	bag:Add(workspace.DescendantAdded:Connect(function(inst)
		if inst:IsA("BasePart") and inst.Anchored then
			queuePartInvalidation(inst)
		end
	end))
	bag:Add(workspace.DescendantRemoving:Connect(function(inst)
		if inst:IsA("BasePart") and inst.Anchored then
			queuePartInvalidation(inst)
		end
	end))

	context.Scheduler:AddJob("PropagationCacheMaintenance", config.Scheduler.CacheMaintenanceSeconds, 8, function()
		local now = os.clock()
		for key, entry in pairs(pathCache) do
			if now - entry.CreatedAt > P.PathCacheTtlSeconds * 2 then
				pathCache[key] = nil
				pathCacheCount -= 1
			end
		end
		table.clear(classifyCache)
		if P.HeightCacheMaxAgeSeconds > 0 and now - heightCacheBornAt > P.HeightCacheMaxAgeSeconds then
			-- Self-heal after un-notified map edits.
			TPS:ClearCaches()
		end
	end)
end

return TPS
