--[[
	EWTestEnvironment
	Builds a reproducible RF test range out of REAL Roblox Terrain and parts at
	EWConfig.TestEnvironment.Origin (default far from typical map content).
	Nothing here scripts an outcome: the stations are ordinary EW devices and
	every result comes from the propagation engine reading this geometry.

	LAYOUT (studs, relative to Origin; flat Grass ground with its top at Y = 0)

	         z = +750   F_W ---------- [ forest ] ---------- F_E
	         z = +400   W_TUNNEL ------------->[ tunnel ]TUNNEL   (tunnel carved into ridge)
	         z = +250   W_RIDGE ------[ RIDGE, top 140 ]------ E_RIDGE      SUMMIT on top, AIR 300 up
	         z = -350   W_OPEN ------------------------------- E_OPEN       (clear line of sight)
	         z = -575                         UW_TX ---- [ pond ] UW_RX (submerged) / SURF_RX (buoy)
	         z = -850..-1150  BLDG_TX ---- RX_OPEN / RX_WOOD / RX_CONCRETE / RX_METAL
	         z = -1300  TC_W ---------- (berm added/removed by test) ---------- TC_E

	Ridge: horizontal terrain cylinder (Rock), radius 210, axis along Z from
	z = -100 to z = +600, crest 140 studs above the plain, ~400 studs wide.
]]

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local EWTestEnvironment = {}

local RIDGE_RADIUS = 210
local RIDGE_CENTER_Y = -70
local RIDGE_Z0, RIDGE_Z1 = -100, 600
local ANTENNA_HEIGHT = 5.5

-- Property order matters: Shape and Size first, then placement via CFrame, Parent last.
-- Terrain writes (FillBlock etc.) are not raycastable until the physics step
-- after the write. Probing in the same frame misses and caches the probe floor
-- as "ground", so wait until each probe column reports the expected surface.
-- probes: { { x, z, minY, maxY } } relative to origin.
local function waitForTerrainCollision(origin: Vector3, probes, timeoutSeconds: number?): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	params.IgnoreWater = true
	local deadline = os.clock() + (timeoutSeconds or 5)
	repeat
		RunService.Heartbeat:Wait()
		local settled = true
		for _, probe in ipairs(probes) do
			local top = Vector3.new(origin.X + probe[1], origin.Y + 1000, origin.Z + probe[2])
			local result = workspace:Raycast(top, Vector3.new(0, -2000, 0), params)
			local y = result and (result.Position.Y - origin.Y)
			if y == nil or y < probe[3] or y > probe[4] then
				settled = false
				break
			end
		end
		if settled then
			return true
		end
	until os.clock() > deadline
	return false
end

local function part(props): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if props.Shape then
		p.Shape = props.Shape
	end
	for k, v in pairs(props) do
		if k ~= "Shape" and k ~= "Position" and k ~= "CFrame" and k ~= "Parent" then
			(p :: any)[k] = v
		end
	end
	if props.CFrame then
		p.CFrame = props.CFrame
	elseif props.Position then
		p.CFrame = CFrame.new(props.Position)
	end
	if props.Parent then
		p.Parent = props.Parent
	end
	return p
end

function EWTestEnvironment.RidgeHeightAt(x: number): number
	local r2 = RIDGE_RADIUS * RIDGE_RADIUS - x * x
	if r2 <= 0 then
		return 0
	end
	return math.max(0, RIDGE_CENTER_Y + math.sqrt(r2))
end

local function makeBox(parent: Instance, name: string, center: Vector3, inner: Vector3, thickness: number, material: Enum.Material, color: Color3)
	local model = Instance.new("Model")
	model.Name = name
	local t = thickness
	local h = inner.Y
	local walls = {
		{ Vector3.new(inner.X + 2 * t, h, t), Vector3.new(0, h / 2, inner.Z / 2 + t / 2) },
		{ Vector3.new(inner.X + 2 * t, h, t), Vector3.new(0, h / 2, -inner.Z / 2 - t / 2) },
		{ Vector3.new(t, h, inner.Z), Vector3.new(inner.X / 2 + t / 2, h / 2, 0) },
		{ Vector3.new(t, h, inner.Z), Vector3.new(-inner.X / 2 - t / 2, h / 2, 0) },
		{ Vector3.new(inner.X + 2 * t, t, inner.Z + 2 * t), Vector3.new(0, h + t / 2, 0) },
	}
	for i, w in ipairs(walls) do
		part({
			Name = "Wall" .. i,
			Size = w[1],
			Position = center + w[2],
			Material = material,
			Color = color,
			Parent = model,
		})
	end
	model.Parent = parent
	return model
end

-- Creates one EW station: an ordinary device made of a stand and a radio part
-- holding the EWDetectable BoolValue and an EWAntenna attachment.
function EWTestEnvironment.CreateStation(env, name: string, basePosition: Vector3, options)
	options = options or {}
	local model = Instance.new("Model")
	model.Name = "Station_" .. name
	local antennaY = basePosition.Y + (options.AntennaHeight or ANTENNA_HEIGHT)
	if not options.NoStand then
		part({
			Name = "Stand",
			Size = Vector3.new(0.6, antennaY - basePosition.Y - 0.5, 0.6),
			Position = Vector3.new(basePosition.X, (basePosition.Y + antennaY - 0.5) / 2, basePosition.Z),
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			Color = Color3.fromRGB(60, 60, 60),
			Parent = model,
		})
	end
	local radio = part({
		Name = "Radio",
		Size = Vector3.new(1, 1, 1),
		Position = Vector3.new(basePosition.X, antennaY - 0.5, basePosition.Z),
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Color = options.Color or Color3.fromRGB(90, 110, 60),
		Material = Enum.Material.SmoothPlastic,
		Parent = model,
	})
	local antenna = Instance.new("Attachment")
	antenna.Name = "EWAntenna"
	antenna.Position = Vector3.new(0, 0.5, 0)
	antenna.Parent = radio
	model.PrimaryPart = radio
	model:SetAttribute("ElectronicType", options.ElectronicType or "Communications")
	model:SetAttribute("SignalProfile", options.Profile or "UHF_FM_VOICE")
	model:SetAttribute("CustomDisplayName", name)
	if options.Channel then
		model:SetAttribute("TransmissionChannel", options.Channel)
	end
	if options.EmissionEnabled ~= nil then
		model:SetAttribute("EmissionEnabled", options.EmissionEnabled)
	end
	local flag = Instance.new("BoolValue")
	flag.Name = "EWDetectable"
	flag.Value = true
	flag.Parent = radio
	model.Parent = env.Folder
	env.Stations[name] = { Model = model, Name = name }
	return model
end

-- Moves a station so its base sits on the ground (or a given Y) at x, z.
function EWTestEnvironment.MoveStation(env, name: string, x: number, z: number, baseY: number?)
	local station = env.Stations[name]
	local y = baseY
	if y == nil then
		y = env.Context.Terrain:SampleGround(env.Origin.X + x, env.Origin.Z + z, true) or env.Origin.Y
	end
	local target = Vector3.new(env.Origin.X + x, (y :: number) + ANTENNA_HEIGHT - 0.5, env.Origin.Z + z)
	station.Model:PivotTo(CFrame.new(target))
	return target + Vector3.new(0, 1, 0) -- antenna position
end

function EWTestEnvironment.GetRecord(env, name: string)
	local station = env.Stations[name]
	return env.Context.Registry:GetByRoot(station.Model)
end

function EWTestEnvironment.Build(context, log: (string) -> ())
	local config = context.Config
	local O: Vector3 = config.TestEnvironment.Origin
	local terrain = workspace.Terrain
	local t0 = os.clock()

	local existing = workspace:FindFirstChild(config.TestEnvironment.FolderName)
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = config.TestEnvironment.FolderName
	folder.Parent = workspace

	local env = {
		Context = context,
		Origin = O,
		Folder = folder,
		Stations = {},
		RidgeTop = RIDGE_CENTER_Y + RIDGE_RADIUS,
	}

	------------------------------------------------------------------ terrain
	-- Ground slab: x -1200..1200, z -1500..900, top at Y = 0 (40 studs thick).
	terrain:FillBlock(CFrame.new(O + Vector3.new(0, -20, -300)), Vector3.new(2400, 40, 2400), Enum.Material.Grass)
	-- Clear anything left above the slab in the lanes we use (previous berm etc.).
	terrain:FillBlock(CFrame.new(O + Vector3.new(0, 100, -1300)), Vector3.new(2400, 200, 200), Enum.Material.Air)
	-- Ridge: horizontal cylinder along Z.
	local ridgeLength = RIDGE_Z1 - RIDGE_Z0
	terrain:FillCylinder(
		CFrame.new(O + Vector3.new(0, RIDGE_CENTER_Y, (RIDGE_Z0 + RIDGE_Z1) / 2)) * CFrame.Angles(math.rad(90), 0, 0),
		ridgeLength,
		RIDGE_RADIUS,
		Enum.Material.Rock
	)
	-- Tunnel into the west flank of the ridge at z = 400 (floor Y = 4, ceiling Y = 16).
	terrain:FillBlock(CFrame.new(O + Vector3.new(-160, 10, 400)), Vector3.new(200, 12, 12), Enum.Material.Air)
	-- Pond: x 400..700, z -650..-500, 24 studs deep.
	terrain:FillBlock(CFrame.new(O + Vector3.new(550, -12, -575)), Vector3.new(300, 24, 150), Enum.Material.Water)
	local settled = waitForTerrainCollision(O, {
		{ -700, -350, -3, 3 }, -- open lane plain
		{ 700, -350, -3, 3 },
		{ 0, 250, RIDGE_CENTER_Y + RIDGE_RADIUS - 6, RIDGE_CENTER_Y + RIDGE_RADIUS + 3 }, -- ridge crest
		{ 0, -1300, -3, 3 }, -- terrain-change lane (berm cleared)
	})
	if not settled then
		log("WARNING: terrain collision did not settle; ground heights may be wrong")
	end
	log(string.format("Terrain built in %.2f s", os.clock() - t0))

	------------------------------------------------------------------ structures
	local structures = Instance.new("Folder")
	structures.Name = "Structures"
	structures.Parent = folder
	-- Light wooden hut, concrete bunker, metal container (each encloses an RX station).
	makeBox(structures, "WoodHut", O + Vector3.new(300, 0, -950), Vector3.new(12, 10, 12), 1, Enum.Material.WoodPlanks, Color3.fromRGB(150, 110, 70))
	makeBox(structures, "ConcreteBunker", O + Vector3.new(300, 0, -1050), Vector3.new(12, 10, 12), 2, Enum.Material.Concrete, Color3.fromRGB(140, 140, 135))
	makeBox(structures, "MetalContainer", O + Vector3.new(300, 0, -1150), Vector3.new(12, 10, 12), 0.3, Enum.Material.DiamondPlate, Color3.fromRGB(80, 95, 80))

	-- Forest patch between F_W and F_E (tagged foliage, canopy spans the antenna height).
	local forest = Instance.new("Folder")
	forest.Name = "Forest"
	forest.Parent = folder
	for ix = -6, 6 do
		for iz = -2, 2 do
			local tree = Instance.new("Model")
			tree.Name = "Tree"
			local x = ix * 22 + (iz % 2) * 11
			local z = 750 + iz * 22
			part({
				Name = "Trunk",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(16, 1.6, 1.6),
				CFrame = CFrame.new(O + Vector3.new(x, 8, z)) * CFrame.Angles(0, 0, math.rad(90)),
				Material = Enum.Material.Wood,
				Color = Color3.fromRGB(90, 64, 40),
				Parent = tree,
			})
			part({
				Name = "Canopy",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(15, 15, 15),
				Position = O + Vector3.new(x, 9, z),
				Material = Enum.Material.LeafyGrass,
				Color = Color3.fromRGB(60, 110, 50),
				CanCollide = false,
				Parent = tree,
			})
			CollectionService:AddTag(tree, "EWVegetation")
			tree.Parent = forest
		end
	end

	------------------------------------------------------------------ stations
	local stations = Instance.new("Folder")
	stations.Name = "Stations"
	stations.Parent = folder
	env.Folder = stations
	local function ground(x, z)
		return context.Terrain:SampleGround(O.X + x, O.Z + z, true) or O.Y
	end
	context.Terrain:ClearCaches()
	local function at(x, z, y)
		return Vector3.new(O.X + x, y or ground(x, z), O.Z + z)
	end

	EWTestEnvironment.CreateStation(env, "W_OPEN", at(-700, -350))
	EWTestEnvironment.CreateStation(env, "E_OPEN", at(700, -350))
	EWTestEnvironment.CreateStation(env, "W_RIDGE", at(-700, 250))
	EWTestEnvironment.CreateStation(env, "E_RIDGE", at(700, 250))
	EWTestEnvironment.CreateStation(env, "SUMMIT", at(0, 250))
	EWTestEnvironment.CreateStation(env, "AIR", at(-700, 250, O.Y + 300), { NoStand = true, Color = Color3.fromRGB(200, 200, 60) })
	EWTestEnvironment.CreateStation(env, "W_TUNNEL", at(-700, 400))
	EWTestEnvironment.CreateStation(env, "TUNNEL", at(-80, 400, O.Y + 4))
	EWTestEnvironment.CreateStation(env, "BLDG_TX", at(-300, -950))
	EWTestEnvironment.CreateStation(env, "RX_OPEN", at(300, -850))
	EWTestEnvironment.CreateStation(env, "RX_WOOD", at(300, -950, O.Y))
	EWTestEnvironment.CreateStation(env, "RX_CONCRETE", at(300, -1050, O.Y))
	EWTestEnvironment.CreateStation(env, "RX_METAL", at(300, -1150, O.Y))
	EWTestEnvironment.CreateStation(env, "TC_W", at(-500, -1300))
	EWTestEnvironment.CreateStation(env, "TC_E", at(500, -1300))
	EWTestEnvironment.CreateStation(env, "F_W", at(-500, 750))
	EWTestEnvironment.CreateStation(env, "F_E", at(500, 750))
	EWTestEnvironment.CreateStation(env, "UW_TX", at(250, -575))
	EWTestEnvironment.CreateStation(env, "SURF_RX", at(550, -545, O.Y - 2.5), { NoStand = true, AntennaHeight = ANTENNA_HEIGHT })
	EWTestEnvironment.CreateStation(env, "UW_RX", at(550, -605, O.Y - 18), { NoStand = true, AntennaHeight = ANTENNA_HEIGHT })
	EWTestEnvironment.CreateStation(env, "MOBILE", at(-700, -700))

	-- With deferred signal behaviour DescendantAdded has not fired yet; yield once
	-- so the registry has seen every station's flag before flushing.
	task.wait()
	context.Registry:Flush()
	context.Terrain:ClearCaches()
	for name in pairs(env.Stations) do
		local record = EWTestEnvironment.GetRecord(env, name)
		if record then
			context.Registry:RefreshPose(record)
		else
			log("WARNING: station not registered: " .. name)
		end
	end
	log(string.format("Test range ready at %s (%d stations) in %.2f s", tostring(O), #stations:GetChildren(), os.clock() - t0))
	return env
end

-- Adds / removes the terrain berm used by the terrain-change test. Returns the
-- affected region so callers can notify the propagation service.
function EWTestEnvironment.SetBerm(env, present: boolean): (Vector3, Vector3)
	local O = env.Origin
	local center = O + Vector3.new(0, 40, -1300)
	local size = Vector3.new(60, 80, 200)
	workspace.Terrain:FillBlock(CFrame.new(center), size, if present then Enum.Material.Ground else Enum.Material.Air)
	if present then
		waitForTerrainCollision(O, { { 0, -1300, 74, 83 } })
	else
		waitForTerrainCollision(O, { { 0, -1300, -3, 3 } })
	end
	return center - size / 2 - Vector3.new(8, 8, 8), center + size / 2 + Vector3.new(8, 8, 8)
end

return EWTestEnvironment
