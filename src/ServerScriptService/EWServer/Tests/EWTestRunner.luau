--[[
	EWTestRunner
	Phase 1 Studio test suite. Run it by setting the attribute
	ServerScriptService.EWServer.EW_RunTests = true (before or during Play), or
	with the "Run Tests" button in the developer diagnostics panel.

	Every measurement goes through the production code path
	(RFSimulationService:EvaluateLink -> TerrainPropagationService) against real
	Terrain/parts built by EWTestEnvironment. Measurements use Force = true
	(bypass the per-frame budget) and Deterministic = true (no random fading)
	so results are reproducible; Test E deliberately uses the normal scheduler
	path instead.

	Tests: A Boolean registration | L Object lifecycle | B Mountain obstruction
	       TC Terrain change (reproducible) | C Buildings | E Dynamic movement
	       H Airborne | U Underground / water / vegetation | G Interference (core)
	       F Detection eligibility (core) | I Battery | J Security | K Performance
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("EWShared")
local SharedUtilities = require(Shared.SharedUtilities)
local Env = require(script.Parent.EWTestEnvironment)

local EWTestRunner = {}

local BANDS = {
	{ Name = "VHF 45 MHz", Profile = "VHF_FM_VOICE", Freq = 45 },
	{ Name = "UHF 300 MHz", Profile = "UHF_FM_VOICE", Freq = 300 },
	{ Name = "L 1350 MHz", Profile = "MANET_DATA_LBAND", Freq = 1350 },
}

local function f1(x: number?): string
	return SharedUtilities.FormatDb(x)
end

local function newCheck(log)
	local check = { Failures = {}, Count = 0 }
	function check.That(cond: boolean, message: string)
		check.Count += 1
		if cond then
			log("    ok   " .. message)
		else
			table.insert(check.Failures, message)
			log("    FAIL " .. message)
		end
	end
	function check.Result(summary: string?)
		return #check.Failures == 0, summary or string.format("%d/%d checks", check.Count - #check.Failures, check.Count)
	end
	return check
end

local function settle(context)
	-- Deferred signal behaviour: let queued events fire, then process the registry queue.
	task.wait()
	context.Registry:Flush()
end

local function setProfile(context, env, names: { string }, band)
	for _, name in ipairs(names) do
		local model = env.Stations[name].Model
		model:SetAttribute("SignalProfile", band.Profile)
		model:SetAttribute("TransmissionChannel", band.Freq)
	end
	settle(context)
end

local function measure(context, env, txName: string, rxName: string, options)
	local tx = Env.GetRecord(env, txName)
	local rx = Env.GetRecord(env, rxName)
	assert(tx, "station not registered: " .. txName)
	assert(rx, "station not registered: " .. rxName)
	return context.RF:EvaluateLink(tx, rx, {
		Force = true,
		Deterministic = true,
		RefreshPose = true,
		IncludeInterference = options and options.Interference or false,
	})
end

local function describe(r): string
	local p = r.Propagation
	if not p then
		return string.format("%s (no propagation: %s)", r.Quality.State, table.concat(r.Reasons, ","))
	end
	return string.format(
		"%-9s margin %6s dB | SINR %6s | Rx %7s dBm | basic %5s (%s) excess %5s [diff %s terr %s struct %s veg %s water %s cav %s] %s/%s | %.0f studs",
		r.Quality.State,
		f1(r.Quality.MarginDb),
		f1(r.SinrDb),
		f1(r.InBandSignalDbm),
		f1(r.BasicLossDb),
		r.BasicModel,
		f1(p.ExcessDb),
		f1(p.DiffractionDb),
		f1(p.TerrainPenetrationDb),
		f1(p.StructureDb),
		f1(p.VegetationDb),
		f1(p.WaterDb),
		f1(p.CavityDb),
		p.Class,
		p.DominantPath,
		r.DistanceStuds
	)
end

local function explain(log, r, limit: number?)
	if r.Propagation then
		for i, line in ipairs(r.Propagation.Explanation) do
			if limit and i > limit then
				break
			end
			log("        . " .. line)
		end
	end
end

--------------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------------

local Tests = {}

table.insert(Tests, {
	Name = "A  Boolean registration (EWDetectable only)",
	Run = function(context, env, log)
		local check = newCheck(log)
		local registry = context.Registry
		local model = Instance.new("Model")
		model.Name = "TestA_Device"
		local p = Instance.new("Part")
		p.Anchored = true
		p.Size = Vector3.new(3, 2, 2)
		p.Position = env.Origin + Vector3.new(0, 1, -600)
		p.Parent = model
		local flag = Instance.new("BoolValue")
		flag.Name = "EWDetectable"
		flag.Value = true
		flag.Parent = model
		model.Parent = env.Folder
		settle(context)

		local record = registry:GetByRoot(model)
		check.That(record ~= nil, "Model with only a BoolValue registers automatically")
		if not record then
			model:Destroy()
			return check.Result()
		end
		check.That(record.DefinitionId == "Generic", "default definition assigned (Generic)")
		check.That(record.Emitters[1].ProfileId == "UNINTENTIONAL_EMISSION", "default signal profile assigned (UNINTENTIONAL_EMISSION)")
		check.That(record.DetectionClass == "PassiveElectronic", "detection class is PassiveElectronic, not a transmitter")
		check.That(registry:IsEligibleForDetection(record), "eligible for detection while EWDetectable = true")
		local function inDetectable()
			for _, entry in ipairs(context.RF:GetDetectableEmissions()) do
				if entry.Record == record then
					return true
				end
			end
			return false
		end
		check.That(inDetectable(), "weak unintentional emission present in detectable emissions")

		flag.Value = false
		settle(context)
		check.That(registry:GetByRoot(model) == record, "EWDetectable = false keeps the device tracked (state preserved)")
		check.That(not registry:IsEligibleForDetection(record), "EWDetectable = false removes it from detection eligibility")
		check.That(not inDetectable(), "EWDetectable = false removes it from detectable emissions")

		flag.Value = true
		settle(context)
		check.That(registry:IsEligibleForDetection(record), "EWDetectable = true restores eligibility")

		flag:Destroy()
		settle(context)
		check.That(registry:GetByRoot(model) == nil, "removing the BoolValue unregisters the device")

		-- BoolValue inside a BasePart of a Model -> root is the Model.
		local flag2 = Instance.new("BoolValue")
		flag2.Name = "EWDetectable"
		flag2.Value = true
		flag2.Parent = p
		settle(context)
		check.That(registry:GetByRoot(model) ~= nil, "BoolValue inside a BasePart resolves to the parent Model as root")

		-- Lone BasePart in a Folder -> root is the part itself.
		local lone = Instance.new("Part")
		lone.Anchored = true
		lone.Size = Vector3.new(2, 2, 2)
		lone.Position = env.Origin + Vector3.new(10, 1, -600)
		local flag3 = Instance.new("BoolValue")
		flag3.Name = "EWDetectable"
		flag3.Value = true
		flag3.Parent = lone
		lone.Parent = env.Folder
		settle(context)
		check.That(registry:GetByRoot(lone) ~= nil, "BoolValue inside a loose BasePart registers the part as root")

		-- Created with default name, renamed after parenting (common scripting pattern).
		local lateModel = Instance.new("Model")
		local latePart = Instance.new("Part")
		latePart.Anchored = true
		latePart.Position = env.Origin + Vector3.new(20, 1, -600)
		latePart.Parent = lateModel
		lateModel.Parent = env.Folder
		local late = Instance.new("BoolValue")
		late.Value = true
		late.Parent = lateModel
		late.Name = "EWDetectable"
		settle(context)
		task.wait()
		settle(context)
		check.That(registry:GetByRoot(lateModel) ~= nil, "BoolValue renamed to EWDetectable after parenting is detected")

		model:Destroy()
		lone:Destroy()
		lateModel:Destroy()
		settle(context)
		check.That(registry:GetByRoot(model) == nil and registry:GetByRoot(lone) == nil, "destroyed devices are unregistered")
		return check.Result()
	end,
})

table.insert(Tests, {
	Name = "L  Object lifecycle (spawn/equip/unequip/move/disable/destroy/recreate)",
	Run = function(context, env, log)
		local check = newCheck(log)
		local registry = context.Registry
		local power = context.Power
		settle(context)
		local baselineConnections = SharedUtilities.GetLiveConnectionCount()
		local baselineDevices = registry:Count()

		local function makeTool(serial: string)
			local tool = Instance.new("Tool")
			tool.Name = "TestL_Radio"
			local handle = Instance.new("Part")
			handle.Name = "Handle"
			handle.Size = Vector3.new(1, 2, 1)
			handle.Anchored = true
			handle.CanCollide = false
			handle.Position = env.Origin + Vector3.new(0, 1.5, -620)
			handle.Parent = tool
			tool:SetAttribute("ElectronicType", "Communications")
			tool:SetAttribute("EWSerial", serial)
			local flag = Instance.new("BoolValue")
			flag.Name = "EWDetectable"
			flag.Value = true
			flag.Parent = handle
			return tool
		end

		local tool = makeTool("TEST-L-001")
		tool.Parent = env.Folder
		settle(context)
		local record = registry:GetByRoot(tool)
		check.That(record ~= nil, "Tool registers with the Tool as root (BoolValue inside Handle)")
		if not record then
			tool:Destroy()
			return check.Result()
		end
		check.That(record.Battery ~= nil, "Communications definition gives the tool a battery")
		power:SetCharge(record, 0.5)

		tool.Parent = ServerStorage
		settle(context)
		check.That(registry:GetByRoot(tool) == nil, "moving the tool out of the world unregisters it")
		tool.Parent = env.Folder
		settle(context)
		local restored = registry:GetByRoot(tool)
		check.That(restored ~= nil, "returning the tool to the world re-registers it")
		if restored then
			local fraction = power:GetBatteryFraction(restored) or -1
			check.That(math.abs(fraction - 0.5) < 0.01, string.format("battery state persisted across containers (%.2f)", fraction))
		end

		-- Real equip / unequip when a player character is available (Play mode).
		local player = Players:GetPlayers()[1]
		local character = player and player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local backpack = player and player:FindFirstChildOfClass("Backpack")
		if humanoid and backpack then
			local handle = tool:FindFirstChild("Handle") :: BasePart
			handle.Anchored = false
			handle.Massless = true
			tool.Parent = backpack
			settle(context)
			local carried = registry:GetByRoot(tool)
			check.That(carried ~= nil and carried.OwnerUserId == player.UserId, "tool in Backpack is registered and owned by the player")
			humanoid:EquipTool(tool)
			task.wait(0.2)
			settle(context)
			local equipped = registry:GetByRoot(tool)
			check.That(equipped ~= nil and equipped == carried, "equipping keeps the same record (no re-registration)")
			humanoid:UnequipTools()
			task.wait(0.2)
			settle(context)
			check.That(registry:GetByRoot(tool) == carried, "unequipping keeps the same record")
			if carried then
				check.That(carried.InWorld, "carried tool has a world position (follows the character)")
			end
		else
			log("    (no player character - equip/unequip checks skipped; run in Play mode to include them)")
		end

		tool:Destroy()
		settle(context)
		check.That(registry:GetByRoot(tool) == nil, "destroying the tool unregisters it")
		local recreated = makeTool("TEST-L-001")
		recreated.Parent = env.Folder
		settle(context)
		local r2 = registry:GetByRoot(recreated)
		check.That(r2 ~= nil, "recreated tool registers")
		if r2 then
			local fraction = power:GetBatteryFraction(r2) or -1
			check.That(math.abs(fraction - 0.5) < 0.01, string.format("state restored by EWSerial after destroy/recreate (%.2f)", fraction))
		end
		recreated:Destroy()

		-- BoolValue moved from one model to another: root migrates.
		local a = Instance.new("Model")
		local pa = Instance.new("Part")
		pa.Anchored = true
		pa.Position = env.Origin + Vector3.new(30, 1, -620)
		pa.Parent = a
		local b = Instance.new("Model")
		local pb = Instance.new("Part")
		pb.Anchored = true
		pb.Position = env.Origin + Vector3.new(40, 1, -620)
		pb.Parent = b
		local flag = Instance.new("BoolValue")
		flag.Name = "EWDetectable"
		flag.Value = true
		flag.Parent = pa
		a.Parent = env.Folder
		b.Parent = env.Folder
		settle(context)
		check.That(registry:GetByRoot(a) ~= nil and registry:GetByRoot(b) == nil, "flag registers its owning model")
		flag.Parent = pb
		settle(context)
		check.That(registry:GetByRoot(a) == nil and registry:GetByRoot(b) ~= nil, "moving the BoolValue migrates the device to the new root")
		a:Destroy()
		b:Destroy()
		task.wait()
		settle(context)
		task.wait()
		settle(context)

		local connections = SharedUtilities.GetLiveConnectionCount()
		check.That(registry:Count() == baselineDevices, string.format("device count back to baseline (%d)", registry:Count()))
		check.That(connections == baselineConnections, string.format("no lingering connections (%d now, %d before)", connections, baselineConnections))
		return check.Result()
	end,
})

table.insert(Tests, {
	Name = "B  Mountain obstruction (same distance, open vs ridge)",
	Run = function(context, env, log)
		local check = newCheck(log)
		for _, band in ipairs(BANDS) do
			setProfile(context, env, { "W_OPEN", "E_OPEN", "W_RIDGE", "E_RIDGE", "SUMMIT" }, band)
			local open = measure(context, env, "W_OPEN", "E_OPEN")
			local ridge = measure(context, env, "W_RIDGE", "E_RIDGE")
			local summit = measure(context, env, "SUMMIT", "E_RIDGE")
			log("  " .. band.Name)
			log("    open   " .. describe(open))
			log("    ridge  " .. describe(ridge))
			explain(log, ridge, 3)
			log("    summit " .. describe(summit))
			if band.Freq ~= 1350 then
				check.That(math.abs(open.DistanceStuds - ridge.DistanceStuds) < 1, band.Name .. ": open and ridge pairs are the same distance")
				check.That(ridge.Propagation.ExcessDb >= open.Propagation.ExcessDb + 15, band.Name .. ": ridge adds >= 15 dB excess loss")
				check.That(ridge.SinrDb <= open.SinrDb - 15, band.Name .. ": ridge SINR at least 15 dB worse")
				check.That(ridge.Propagation.Class == "Obstructed" or ridge.Propagation.Class == "HeavilyObstructed", band.Name .. ": ridge path classified obstructed")
				check.That(open.Propagation.Class == "Unobstructed" or open.Propagation.Class == "PartiallyObstructed", band.Name .. ": open path classified unobstructed/partial")
				check.That(summit.Quality.MarginDb >= ridge.Quality.MarginDb + 15, band.Name .. ": moving onto the ridge crest restores the link (>= 15 dB better)")
			else
				check.That(ridge.Quality.MarginDb < open.Quality.MarginDb - 30, band.Name .. ": L-band is far more terrain-sensitive (>= 30 dB worse)")
			end
		end
		return check.Result()
	end,
})

table.insert(Tests, {
	Name = "TC Terrain change: adding/removing real Terrain changes link quality",
	Run = function(context, env, log)
		local check = newCheck(log)
		for _, band in ipairs({ BANDS[1], BANDS[2] }) do
			setProfile(context, env, { "TC_W", "TC_E" }, band)
			local before = measure(context, env, "TC_W", "TC_E")
			local lo, hi = Env.SetBerm(env, true)
			context.Terrain:NotifyTerrainChanged(lo, hi)
			local during = measure(context, env, "TC_W", "TC_E")
			lo, hi = Env.SetBerm(env, false)
			context.Terrain:NotifyTerrainChanged(lo, hi)
			local after = measure(context, env, "TC_W", "TC_E")
			log("  " .. band.Name)
			log("    flat        " .. describe(before))
			log("    with berm   " .. describe(during))
			explain(log, during, 2)
			log("    berm removed" .. describe(after))
			check.That(during.Propagation.ExcessDb >= before.Propagation.ExcessDb + 8, band.Name .. ": Terrain:FillBlock berm adds >= 8 dB")
			check.That(during.Quality.MarginDb <= before.Quality.MarginDb - 8, band.Name .. ": link margin drops >= 8 dB with the berm")
			check.That(math.abs(after.Propagation.ExcessDb - before.Propagation.ExcessDb) <= 1.0, band.Name .. ": removing the berm restores the original link (+-1 dB)")
		end
		return check.Result()
	end,
})

table.insert(Tests, {
	Name = "C  Building obstruction (open / wood / concrete / metal)",
	Run = function(context, env, log)
		local check = newCheck(log)
		for _, band in ipairs(BANDS) do
			setProfile(context, env, { "BLDG_TX", "RX_OPEN", "RX_WOOD", "RX_CONCRETE", "RX_METAL" }, band)
			local open = measure(context, env, "BLDG_TX", "RX_OPEN")
			local wood = measure(context, env, "BLDG_TX", "RX_WOOD")
			local concrete = measure(context, env, "BLDG_TX", "RX_CONCRETE")
			local metal = measure(context, env, "BLDG_TX", "RX_METAL")
			log("  " .. band.Name)
			log("    open     " .. describe(open))
			log("    wood     " .. describe(wood))
			log("    concrete " .. describe(concrete))
			explain(log, concrete, 2)
			log("    metal    " .. describe(metal))
			local e0, e1, e2, e3 = open.Propagation.ExcessDb, wood.Propagation.ExcessDb, concrete.Propagation.ExcessDb, metal.Propagation.ExcessDb
			check.That(e1 > e0, band.Name .. ": wood hut attenuates more than open space")
			check.That(e2 > e1 + 2, band.Name .. ": concrete bunker attenuates clearly more than wood")
			check.That(e3 > e1 + 5, band.Name .. ": metal container attenuates strongly")
		end
		return check.Result()
	end,
})

table.insert(Tests, {
	Name = "E  Dynamic movement (scheduler-driven, no scripted regions)",
	Run = function(context, env, log)
		local check = newCheck(log)
		local band = BANDS[2]
		setProfile(context, env, { "MOBILE", "E_RIDGE" }, band)
		local mobile = Env.GetRecord(env, "MOBILE")
		local rx = Env.GetRecord(env, "E_RIDGE")
		local watchId = context.RF:WatchLink(mobile.Id, rx.Id, { Priority = 1, Deterministic = true, Label = "TestE MOBILE->E_RIDGE" })
		local watch = context.RF:GetWatch(watchId)
		local route = {}
		local function leg(x0, z0, x1, z1, step)
			local d = math.sqrt((x1 - x0) ^ 2 + (z1 - z0) ^ 2)
			local n = math.max(1, math.floor(d / step))
			for i = 0, n do
				local t = i / n
				table.insert(route, { x0 + (x1 - x0) * t, z0 + (z1 - z0) * t })
			end
		end
		leg(-700, -700, -700, 250, 95) -- open -> behind the ridge
		leg(-700, 250, 0, 250, 100) -- climb to the crest
		leg(0, 250, -700, -700, 160) -- back to the start
		local samples = {}
		local evaluationsBefore = watch.Evaluations
		for _, point in ipairs(route) do
			local antenna = Env.MoveStation(env, "MOBILE", point[1], point[2])
			local movedAt = os.clock()
			local deadline = movedAt + 5
			-- Wait for a FRESH scheduler evaluation at the new position (not a stale reuse).
			repeat
				task.wait(0.05)
				local fresh = watch.LastResult ~= nil
					and watch.LastResult.Timestamp >= movedAt
					and watch.LastResult.AnalysisMode ~= "Cached"
					and watch.LastTxPos ~= nil
					and (watch.LastTxPos - antenna).Magnitude < 1.5
			until fresh or os.clock() > deadline
			local r = watch.LastResult
			if r then
				table.insert(samples, { X = point[1], Z = point[2], Margin = r.Quality.MarginDb, State = r.Quality.State, Class = r.Propagation and r.Propagation.Class or "?" })
				log(string.format("    (%5.0f,%5.0f) %-9s margin %6s dB %s", point[1], point[2], r.Quality.State, f1(r.Quality.MarginDb), r.Propagation and r.Propagation.Class or ""))
			end
		end
		context.RF:UnwatchLink(watchId, "TestComplete")
		Env.MoveStation(env, "MOBILE", -700, -700)
		local evaluations = watch.Evaluations - evaluationsBefore
		check.That(#samples >= #route * 0.9, string.format("watched link updated for %d/%d positions", #samples, #route))
		check.That(evaluations >= #route * 0.9, string.format("updates came from the scheduler (%d evaluations, none forced)", evaluations))
		if #samples > 3 then
			local start = samples[1].Margin
			local worst, worstIndex = math.huge, 1
			for i, s in ipairs(samples) do
				if s.Margin < worst then
					worst, worstIndex = s.Margin, i
				end
			end
			local crestIndex = nil
			for i, s in ipairs(samples) do
				if s.X == 0 and s.Z == 250 then
					crestIndex = i
					break
				end
			end
			local finish = samples[#samples].Margin
			check.That(worst <= start - 15, string.format("moving behind the ridge degrades the link (start %s, worst %s at %.0f,%.0f)", f1(start), f1(worst), samples[worstIndex].X, samples[worstIndex].Z))
			if crestIndex then
				check.That(samples[crestIndex].Margin >= worst + 15, "climbing to the crest improves the link >= 15 dB")
			end
			check.That(math.abs(finish - start) <= 2, string.format("returning to the start restores the link (%s vs %s)", f1(finish), f1(start)))
		end
		return check.Result()
	end,
})

table.insert(Tests, {
	Name = "H  Airborne platform vs ground (altitude helps, but does not guarantee)",
	Run = function(context, env, log)
		local check = newCheck(log)
		for _, band in ipairs({ BANDS[2], BANDS[3] }) do
			setProfile(context, env, { "AIR", "W_RIDGE", "E_RIDGE", "TUNNEL" }, band)
			local ground = measure(context, env, "W_RIDGE", "E_RIDGE")
			local air = measure(context, env, "AIR", "E_RIDGE")
			local airToTunnel = measure(context, env, "AIR", "TUNNEL")
			log("  " .. band.Name)
			log("    ground->ground " .. describe(ground))
			log("    air->ground    " .. describe(air))
			log("    air->tunnel    " .. describe(airToTunnel))
			check.That(air.Propagation.ExcessDb <= ground.Propagation.ExcessDb - 15, band.Name .. ": elevated platform clears the ridge (>= 15 dB less excess)")
			check.That(air.Quality.MarginDb >= ground.Quality.MarginDb + 15, band.Name .. ": elevated platform link margin >= 15 dB better")
			check.That(airToTunnel.Quality.MarginDb <= air.Quality.MarginDb - 20, band.Name .. ": altitude does not reach a receiver deep in a tunnel")
		end
		return check.Result()
	end,
})

table.insert(Tests, {
	Name = "U  Underground, water and vegetation",
	Run = function(context, env, log)
		local check = newCheck(log)
		for _, band in ipairs({ BANDS[1], BANDS[2] }) do
			setProfile(context, env, { "W_TUNNEL", "TUNNEL", "W_RIDGE", "UW_TX", "SURF_RX", "UW_RX", "F_W", "F_E" }, band)
			local aligned = measure(context, env, "W_TUNNEL", "TUNNEL")
			local offAxis = measure(context, env, "W_RIDGE", "TUNNEL")
			local surface = measure(context, env, "UW_TX", "SURF_RX")
			local submerged = measure(context, env, "UW_TX", "UW_RX")
			local forest = measure(context, env, "F_W", "F_E")
			log("  " .. band.Name)
			log("    tunnel (straight, LOS out the mouth) " .. describe(aligned))
			explain(log, aligned, 2)
			log("    tunnel (off-axis through rock)       " .. describe(offAxis))
			log("    buoy antenna above water             " .. describe(surface))
			log("    submerged antenna                    " .. describe(submerged))
			log("    through forest                       " .. describe(forest))
			check.That(offAxis.Propagation.ExcessDb >= aligned.Propagation.ExcessDb + 15, band.Name .. ": receiver deep underground off-axis is heavily degraded")
			check.That(submerged.Propagation.ExcessDb >= surface.Propagation.ExcessDb + 8, band.Name .. ": submerged antenna loses >= 8 dB")
			check.That(forest.Propagation.VegetationDb > 1, band.Name .. ": vegetation contributes attenuation")
			if band.Freq < 100 then
				check.That(aligned.Propagation.ExcessDb >= 20, band.Name .. ": low VHF cannot escape a tunnel (below waveguide cutoff)")
			end
		end
		return check.Result()
	end,
})

table.insert(Tests, {
	Name = "G  Interference (core): co-channel degrades, off-channel does not",
	Run = function(context, env, log)
		local check = newCheck(log)
		local band = BANDS[2]
		setProfile(context, env, { "BLDG_TX", "RX_OPEN" }, band)
		local baseline = measure(context, env, "BLDG_TX", "RX_OPEN", { Interference = true })
		local interferer = Env.CreateStation(env, "TEST_INTERFERER", env.Origin + Vector3.new(380, 0, -800), {
			ElectronicType = "ActiveTransmitter",
			Profile = "UHF_FM_VOICE",
			Channel = 300,
			EmissionEnabled = true,
		})
		settle(context)
		local interfered = measure(context, env, "BLDG_TX", "RX_OPEN", { Interference = true })
		interferer:SetAttribute("TransmissionChannel", 310)
		settle(context)
		local offChannel = measure(context, env, "BLDG_TX", "RX_OPEN", { Interference = true })
		log("    baseline     " .. describe(baseline) .. " I=" .. f1(baseline.InterferenceDbm))
		log("    co-channel   " .. describe(interfered) .. " I=" .. f1(interfered.InterferenceDbm))
		log("    off-channel  " .. describe(offChannel) .. " I=" .. f1(offChannel.InterferenceDbm))
		check.That(interfered.SinrDb <= baseline.SinrDb - 10, "co-channel emitter reduces SINR >= 10 dB")
		check.That(math.abs(offChannel.SinrDb - baseline.SinrDb) <= 1, "emitter moved 10 MHz away has no effect")
		local rx = Env.GetRecord(env, "RX_OPEN")
		check.That(rx.PowerState == "On", "interference degrades communication without powering the receiver down")
		interferer:Destroy()
		env.Stations.TEST_INTERFERER = nil
		settle(context)
		return check.Result()
	end,
})

table.insert(Tests, {
	Name = "F  Detection eligibility (core): active, deactivated, non-detectable",
	Run = function(context, env, log)
		local check = newCheck(log)
		local beacon = Env.CreateStation(env, "TEST_BEACON", env.Origin + Vector3.new(0, 0, -700), {
			ElectronicType = "ActiveTransmitter",
			Profile = "BEACON_UHF",
			EmissionEnabled = true,
		})
		settle(context)
		local record = Env.GetRecord(env, "TEST_BEACON")
		local function listed(list)
			for _, entry in ipairs(list) do
				if entry.Record == record then
					return true
				end
			end
			return false
		end
		check.That(listed(context.RF:GetDetectableEmissions()), "active detectable transmitter is listed")
		beacon:SetAttribute("EmissionEnabled", false)
		settle(context)
		check.That(not listed(context.RF:GetActiveEmissions()), "deactivated transmitter stops emitting")
		beacon:SetAttribute("EmissionEnabled", true)
		local flag = beacon:FindFirstChild("EWDetectable", true) :: BoolValue
		flag.Value = false
		settle(context)
		check.That(listed(context.RF:GetActiveEmissions()), "EWDetectable = false: still physically emitting")
		check.That(not listed(context.RF:GetDetectableEmissions()), "EWDetectable = false: excluded from detection results")
		beacon:Destroy()
		env.Stations.TEST_BEACON = nil
		settle(context)
		return check.Result()
	end,
})

table.insert(Tests, {
	Name = "I  Battery exhaustion, replacement and boot",
	Run = function(context, env, log)
		local check = newCheck(log)
		local power = context.Power
		setProfile(context, env, { "W_OPEN", "E_OPEN" }, BANDS[2])
		local tx = Env.GetRecord(env, "W_OPEN")
		local idle = power:CurrentDrawW(tx)
		context.Registry:SetEmitterTransmitting(tx, 1, true)
		local keyed = power:CurrentDrawW(tx)
		context.Registry:SetEmitterTransmitting(tx, 1, false)
		check.That(keyed > idle * 2, string.format("transmitting draws more power (%.1f W vs %.1f W)", keyed, idle))
		local before = measure(context, env, "W_OPEN", "E_OPEN")
		power:SetCharge(tx, 0)
		local dead = measure(context, env, "W_OPEN", "E_OPEN")
		check.That(tx.PowerState == "Depleted", "empty battery shuts the radio down (Depleted)")
		check.That(dead.Quality.State == "Offline", "link is Offline while the transmitter is depleted")
		local ok = power:SetPower(tx, true)
		check.That(not ok, "cannot power on with an empty battery")
		power:ReplaceBattery(tx, 1)
		check.That(tx.PowerState == "Off", "battery swap leaves the radio Off")
		power:SetPower(tx, true)
		check.That(tx.PowerState == "Booting", "power-on starts the boot sequence")
		local deadline = os.clock() + 6
		repeat
			task.wait(0.25)
		until tx.PowerState == "On" or os.clock() > deadline
		check.That(tx.PowerState == "On", "boot completes")
		local after = measure(context, env, "W_OPEN", "E_OPEN")
		check.That(after.Quality.State == before.Quality.State, "link quality returns after battery replacement")
		return check.Result()
	end,
})

table.insert(Tests, {
	Name = "J  Security validation (server-side)",
	Run = function(context, env, log)
		local check = newCheck(log)
		local security = context.Security
		local schema = {
			Action = { Type = "string", Enum = { "TogglePower", "SetPower", "QueryStatus" } },
			Device = { Type = "Instance" },
			On = { Type = "boolean", Optional = true },
		}
		local someDevice = env.Stations.W_OPEN.Model
		local cases = {
			{ "non-table payload", "TogglePower" },
			{ "missing device", { Action = "TogglePower" } },
			{ "wrong device type", { Action = "TogglePower", Device = "W_OPEN" } },
			{ "unknown action", { Action = "Explode", Device = someDevice } },
			{ "unexpected field", { Action = "TogglePower", Device = someDevice, Range = 1e9 } },
			{ "oversized string", { Action = string.rep("A", 500), Device = someDevice } },
			{ "wrong field type", { Action = "SetPower", Device = someDevice, On = "yes" } },
		}
		for _, case in ipairs(cases) do
			local ok, reason = security:ValidatePayload(case[2], schema)
			check.That(not ok, "rejects " .. case[1] .. " (" .. tostring(reason) .. ")")
		end
		local valid = security:ValidatePayload({ Action = "SetPower", Device = someDevice, On = true }, schema)
		check.That(valid, "accepts a well-formed request")

		local fakePlayer = { UserId = -42, Name = "FakePlayer", Character = nil }
		local allowed = 0
		for _ = 1, 30 do
			if security:CheckRate(fakePlayer :: any, "DeviceCommand") then
				allowed += 1
			end
		end
		check.That(allowed < 30, string.format("rate limiter blocks a 30-request burst (%d allowed)", allowed))

		local record = Env.GetRecord(env, "W_OPEN")
		local ok1, why1 = security:CanControlDevice(fakePlayer :: any, record)
		check.That(not ok1, "world device cannot be controlled without a nearby character (" .. tostring(why1) .. ")")
		local previousOwner = record.OwnerUserId
		record.OwnerUserId = 999999
		local ok2, why2 = security:CanControlDevice(fakePlayer :: any, record)
		record.OwnerUserId = previousOwner
		check.That(not ok2 and why2 == "NOT_OWNER", "another player's carried device cannot be controlled")
		local player = Players:GetPlayers()[1]
		if player and player.Character then
			local ok3, why3 = security:CanControlDevice(player, Env.GetRecord(env, "E_OPEN"))
			check.That(not ok3, "real player far from a world device is refused (" .. tostring(why3) .. ")")
		end
		log("    Client-side remote abuse test: see docs/PHASE1_GUIDE.md (Test J)")
		return check.Result()
	end,
})

table.insert(Tests, {
	Name = "K  Performance stress (moving devices, watched links, active emitters)",
	Run = function(context, env, log)
		local check = newCheck(log)
		local scheduler = context.Scheduler
		local profile, profileName = scheduler:GetProfile()
		local deviceCount, linkCount, emitterCount = 60, 40, 6
		local folder = Instance.new("Folder")
		folder.Name = "StressDevices"
		folder.Parent = env.Folder
		local models = {}
		for i = 1, deviceCount do
			local angle = (i / deviceCount) * math.pi * 2
			local radius = 300 + (i % 5) * 120
			local x, z = math.cos(angle) * radius, -350 + math.sin(angle) * radius * 0.6
			local model = Env.CreateStation(env, "STRESS_" .. i, env.Origin + Vector3.new(x, 0, z), {
				Profile = "UHF_FM_VOICE",
				Channel = 300 + (i % 4) * 0.025,
				EmissionEnabled = i <= emitterCount,
			})
			model.Parent = folder
			table.insert(models, { Model = model, Angle = angle, Radius = radius })
		end
		settle(context)
		local watchIds = {}
		for i = 1, linkCount do
			local a = Env.GetRecord(env, "STRESS_" .. i)
			local b = Env.GetRecord(env, "STRESS_" .. ((i + 17) % deviceCount + 1))
			if a and b then
				table.insert(watchIds, context.RF:WatchLink(a.Id, b.Id, { Priority = 2 }))
			end
		end
		scheduler:ResetMaxima()
		local before = scheduler:GetStats()
		local rfBefore = context.RF:GetStats()
		local terrainBefore = context.Terrain:GetStats()
		local t0 = os.clock()
		local duration = 10
		local mover = RunService.Heartbeat:Connect(function(dt)
			for _, m in ipairs(models) do
				m.Angle += dt * 0.15
				local x, z = math.cos(m.Angle) * m.Radius, -350 + math.sin(m.Angle) * m.Radius * 0.6
				m.Model:PivotTo(CFrame.new(env.Origin + Vector3.new(x, 5, z)))
			end
		end)
		task.wait(duration)
		mover:Disconnect()
		local elapsed = os.clock() - t0
		local after = scheduler:GetStats()
		local rfAfter = context.RF:GetStats()
		local terrainAfter = context.Terrain:GetStats()
		local frames = after.Frames - before.Frames
		local evaluations = rfAfter.WatchEvaluations - rfBefore.WatchEvaluations
		local rays = after.RaycastsTotal - before.RaycastsTotal
		local overBudget = after.OverBudgetFrames - before.OverBudgetFrames
		local hits = terrainAfter.CacheHits - terrainBefore.CacheHits
		local misses = terrainAfter.CacheMisses - terrainBefore.CacheMisses
		log(string.format("    profile %s: %d devices (%d emitting), %d watched links, %.1f s", profileName, deviceCount, emitterCount, #watchIds, elapsed))
		log(string.format("    frames %d | EW frame cost avg %.2f ms max %.2f ms (budget %.1f ms) | over-budget frames %d", frames, after.FrameCostMsAvg, after.FrameCostMsMax, profile.FrameBudgetMs, overBudget))
		log(string.format("    link evaluations %d (%.0f/s) | raycasts %d (%.0f/s, budget %d/frame) | path cache hits %d misses %d", evaluations, evaluations / elapsed, rays, rays / elapsed, profile.RaycastsPerFrame, hits, misses))
		for _, job in ipairs(after.Jobs) do
			log(string.format("      job %-28s avg %.3f ms max %.3f ms runs %d skipped %d errors %d", job.Name, job.AvgCostMs, job.MaxCostMs, job.Runs, job.Skipped, job.Errors))
		end
		check.That(evaluations >= #watchIds, "every watched link was evaluated at least once under load")
		check.That(after.FrameCostMsAvg <= profile.FrameBudgetMs * 1.5, "average EW frame cost stays near the profile budget")
		check.That(rays / math.max(frames, 1) <= profile.RaycastsPerFrame * 1.1, "raycast usage respects the per-frame budget")
		for _, id in ipairs(watchIds) do
			context.RF:UnwatchLink(id, "TestComplete")
		end
		for i = 1, deviceCount do
			env.Stations["STRESS_" .. i] = nil
		end
		folder:Destroy()
		settle(context)
		return check.Result()
	end,
})

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------

function EWTestRunner.RunAll(context, log: (string) -> ())
	log("==== EW PHASE 1 TEST SUITE ====")
	log(string.format("MetersPerStud %.2f | RangeScale %.1f", context.Config.Units.MetersPerStud, context.Config.Units.RangeScale))
	local env = Env.Build(context, log)
	local results = {}
	for _, test in ipairs(Tests) do
		log("---- " .. test.Name)
		local t0 = os.clock()
		local ok, passed, summary = pcall(test.Run, context, env, log)
		if not ok then
			log("    ERROR " .. tostring(passed))
			table.insert(results, { Name = test.Name, Passed = false, Summary = "error: " .. tostring(passed) })
		else
			table.insert(results, { Name = test.Name, Passed = passed, Summary = summary })
		end
		log(string.format("     => %s (%.1f s)", if ok and passed then "PASS" else "FAIL", os.clock() - t0))
	end
	log("==== SUMMARY ====")
	local passedCount = 0
	for _, r in ipairs(results) do
		if r.Passed then
			passedCount += 1
		end
		log(string.format("  %s  %s  (%s)", if r.Passed then "PASS" else "FAIL", r.Name, r.Summary))
	end
	log(string.format("%d/%d tests passed. Test range kept at %s for inspection.", passedCount, #results, tostring(env.Origin)))
	return results
end

return EWTestRunner
