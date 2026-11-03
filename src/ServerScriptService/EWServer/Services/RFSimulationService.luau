--[[
	RFSimulationService
	The central electromagnetic environment. Every system that needs to know
	"how strong is emitter X at point Y" or "does this link work" asks here, so
	radios, jammers, ES receivers, drones and relays share one consistent model.

	LINK BUDGET (all in dB / dBm, see docs/PHASE1_ARCHITECTURE.md section 4)
	  EIRP      = TxPower + TxAntennaGain(direction)
	  PathLoss  = Basic(FSPL | plane-earth, effective antenna heights)
	            + Excess(terrain diffraction / penetration, structures, vegetation, water)
	            + Weather(rain/snow/fog, frequency dependent)
	            + Polarization mismatch
	  Fading    = shadow (spatially correlated) + small-scale (Rician/Rayleigh, Doppler-correlated)
	            + equipment instability jitter
	  Received  = EIRP + RxAntennaGain - PathLoss + Fading
	  InBand    = Received - CouplingLoss (frequency / bandwidth overlap)
	  Noise     = kTB + (receiver NF combined with ITU-R P.372 external noise)
	  SINR      = InBand - (Noise (+) Interference)      (+) = power sum
	  Quality   = SignalQualityService(SINR - RequiredSinr, compatibility, power)

	A LinkResult describes the POTENTIAL quality of the link if the transmitter
	keys (TxActive tells whether it actually is). Presentation of traffic is done
	by later phases using this result.

	API
	  RF:EvaluateLink(txRecord, rxRecord, options) -> LinkResult
	      options = { EmitterIndex?, ReceiverIndex?, Force?, Deterministic?,
	                  IncludeInterference?, Priority?, Previous?, FadeState?, RefreshPose? }
	  RF:ComputeReceivedPower(txRecord, emitterIndex, rxPosition, rxCFrame, rxAntenna, options)
	      -> (receivedDbm, breakdown)   generic propagation for any receiver point
	  RF:ComputeInterferenceDbm(receiver, rxRecord, rxPosition, rxCFrame, excludeEmitterId, options)
	      -> (interferenceDbm, count, contributions)
	  RF:WatchLink(txId, rxId, options) -> watchId     (scheduler keeps it updated)
	  RF:UnwatchLink(watchId)
	  RF:GetWatch(watchId) / RF:GetWatches()
	  RF:GetActiveEmissions() -> { {Record, Emitter, Index} }
	  RF:GetDetectableEmissions() -> same, filtered by EWDetectable eligibility
	SIGNALS
	  LinkUpdated(watchId, LinkResult)
	  LinkRemoved(watchId, reason)
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("EWShared")
local RFMath = require(Shared.RFMath)
local SignalCompatibility = require(Shared.SignalCompatibility)
local SharedUtilities = require(Shared.SharedUtilities)
local Types = require(Shared.EWTypes)

type DeviceRecord = Types.DeviceRecord
type LinkResult = Types.LinkResult

local RF = {}

RF.LinkUpdated = SharedUtilities.Signal.new("LinkUpdated")
RF.LinkRemoved = SharedUtilities.Signal.new("LinkRemoved")

local context
local config
local registry
local terrainService
local qualityService
local environment

local activeEmissions: { [string]: { Record: DeviceRecord, Emitter: any, Index: number } } = {}
local activeCount = 0

type Watch = {
	Id: string,
	TxId: string,
	RxId: string,
	EmitterIndex: number,
	ReceiverIndex: number,
	Priority: number,
	Label: string,
	IncludeInterference: boolean,
	Deterministic: boolean,
	NextDue: number,
	LastTxPos: Vector3?,
	LastRxPos: Vector3?,
	LastResult: LinkResult?,
	FadeState: any,
	Evaluations: number,
	CreatedAt: number,
}
local watches: { [string]: Watch } = {}
local watchList: { Watch } = {}
local watchCursor = 1
local nextWatchNumber = 0
local oneShotRandom = Random.new()

local stats = {
	Evaluations = 0,
	ForcedEvaluations = 0,
	DeferredEvaluations = 0,
	InterferenceEvaluations = 0,
	EvaluationMsAvg = 0,
	EvaluationMsMax = 0,
	WatchEvaluations = 0,
}

--------------------------------------------------------------------------------
-- Active emission bookkeeping (event driven)
--------------------------------------------------------------------------------

local function refreshActive(record: DeviceRecord)
	for index, emitter in ipairs(record.Emitters) do
		local key = emitter.Id
		local active = record.PowerState == "On" and emitter.Transmitting and record.InWorld and registry:GetDevice(record.Id) == record
		if active and not activeEmissions[key] then
			activeEmissions[key] = { Record = record, Emitter = emitter, Index = index }
			activeCount += 1
		elseif not active and activeEmissions[key] then
			activeEmissions[key] = nil
			activeCount -= 1
		elseif active then
			-- Emitter table may have been rebuilt by a reconfiguration.
			activeEmissions[key].Emitter = emitter
		end
	end
	-- Drop stale entries for emitters that no longer exist on this record.
	for key, entry in pairs(activeEmissions) do
		if entry.Record == record and not record.Emitters[entry.Index] then
			activeEmissions[key] = nil
			activeCount -= 1
		end
	end
end

local function removeAllFor(record: DeviceRecord)
	for key, entry in pairs(activeEmissions) do
		if entry.Record == record then
			activeEmissions[key] = nil
			activeCount -= 1
		end
	end
end

function RF:GetActiveEmissions()
	local out = {}
	for _, entry in pairs(activeEmissions) do
		table.insert(out, entry)
	end
	return out
end

-- Emissions eligible to appear in electronic DETECTION results (EWDetectable = true).
function RF:GetDetectableEmissions()
	local out = {}
	for _, entry in pairs(activeEmissions) do
		if registry:IsEligibleForDetection(entry.Record) then
			table.insert(out, entry)
		end
	end
	return out
end

function RF:GetActiveEmissionCount(): number
	return activeCount
end

--------------------------------------------------------------------------------
-- Geometry helpers
--------------------------------------------------------------------------------

local function antennaAxis(cf: CFrame, polarization: string): Vector3
	if polarization == "Horizontal" then
		return cf.RightVector
	end
	return cf.UpVector
end

local function effectiveHeightMeters(position: Vector3, ground: number, meanGround: number, antenna, mps: number): number
	local localStuds = position.Y - ground
	if localStuds < 0 then
		-- Antenna under a roof/overhang: assume it stands on a floor at its mounting height.
		localStuds = antenna.HeightOffsetStuds
	end
	local aboveMean = position.Y - meanGround
	return math.max(math.max(localStuds, aboveMean) * mps, 0.5)
end

local function newFadeState(seed: number)
	return { G1 = 0, G2 = 0, Time = os.clock(), Rng = Random.new(seed), Initialized = false }
end

local function gaussian(rng: Random): number
	local u1 = math.max(rng:NextNumber(), 1e-9)
	local u2 = rng:NextNumber()
	return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

-- Returns (shadowDb, fastDb, jitterDb) as GAINS (positive = stronger signal).
local function computeFading(class: string, txRecord: DeviceRecord, rxRecord: DeviceRecord?, txPos: Vector3, rxPos: Vector3, frequencyMHz: number, stability: number, fadeState)
	local F = config.Fading
	if not F.Enabled then
		return 0, 0, 0
	end
	local sigma = F.ShadowSigmaDb[class] or 3
	local decor = F.ShadowDecorrelationStuds
	local seed = 7919 + math.floor(math.log10(math.max(frequencyMHz, 1)) * 10)
	local n1 = RFMath.GaussianValueNoise2D(txPos.X, txPos.Z, decor, seed)
	local n2 = RFMath.GaussianValueNoise2D(rxPos.X, rxPos.Z, decor, seed + 31)
	local shadow = sigma * (n1 + n2) / math.sqrt(2)

	local k = F.RicianK[class] or 1
	local rng = if fadeState then fadeState.Rng else oneShotRandom
	local g1, g2
	if fadeState then
		local t = os.clock()
		local dt = math.max(t - fadeState.Time, 0)
		fadeState.Time = t
		local relative = txRecord.Velocity - (if rxRecord then rxRecord.Velocity else Vector3.zero)
		local speed = relative.Magnitude * config.Units.MetersPerStud
		local doppler = speed / RFMath.WavelengthMeters(frequencyMHz) + F.MinDopplerHz
		local tau = 0.423 / doppler
		local rho = if fadeState.Initialized then math.exp(-dt / tau) else 0
		local s = math.sqrt(math.max(1 - rho * rho, 0))
		fadeState.G1 = rho * fadeState.G1 + s * gaussian(rng)
		fadeState.G2 = rho * fadeState.G2 + s * gaussian(rng)
		fadeState.Initialized = true
		g1, g2 = fadeState.G1, fadeState.G2
	else
		g1, g2 = gaussian(rng), gaussian(rng)
	end
	local fast = RFMath.RicianPowerGainDb(g1, g2, k, F.DeepFadeFloorDb)
	local jitter = math.clamp((1 - stability) * F.EquipmentJitterMaxDb * gaussian(rng), -F.EquipmentJitterMaxDb, F.EquipmentJitterMaxDb)
	return shadow, fast, jitter
end

--------------------------------------------------------------------------------
-- Core propagation
--------------------------------------------------------------------------------

--[[
	propagate(): shared physics for links, interference and (later) detection.
	Returns a breakdown table; never decides intelligibility.
]]
local function propagate(txRecord: DeviceRecord, emitter, rxRecord: DeviceRecord?, rxPos: Vector3, rxCF: CFrame, rxAntenna, frequencyMHz: number, options)
	local mps = config.Units.MetersPerStud
	local txPos = txRecord.Position
	local txCF = txRecord.AntennaCFrame
	local delta = rxPos - txPos
	local dStuds = delta.Magnitude
	local dMeters = math.max(dStuds * mps, config.Units.MinLinkDistanceMeters)
	local dir = if dStuds > 1e-4 then delta / dStuds else Vector3.new(0, 0, -1)

	local exclude = { txRecord.Root }
	if rxRecord then
		table.insert(exclude, rxRecord.Root)
	end
	local geometry = terrainService:AnalyzePath(txPos, rxPos, {
		ExcludeInstances = exclude,
		Priority = options.Priority or 2,
		Force = options.Force == true,
	})

	local out = {
		DistanceStuds = dStuds,
		DistanceMeters = dMeters,
		Geometry = geometry,
		Losses = nil,
		AnalysisMode = "Deferred",
		Stale = true,
	}
	if geometry == nil then
		return out
	end
	out.AnalysisMode = geometry.Mode
	out.Stale = geometry.Approximate
	local losses = terrainService:ComputeLosses(geometry, frequencyMHz)
	out.Losses = losses

	local groundTx = terrainService:GetEndpointGround(geometry, txPos)
	local groundRx = terrainService:GetEndpointGround(geometry, rxPos)
	local hTx = effectiveHeightMeters(txPos, groundTx, geometry.MeanInteriorGround, emitter.Antenna, mps)
	local hRx = effectiveHeightMeters(rxPos, groundRx, geometry.MeanInteriorGround, rxAntenna, mps)
	local rangeMeters = dMeters * config.Units.RangeScale
	local basic, fspl, planeEarth, model = RFMath.BasicTransmissionLossDb(rangeMeters, hTx, hRx, frequencyMHz)

	local ta = emitter.Antenna
	local txGain = RFMath.AntennaGainDbi(ta.Pattern, ta.GainDbi, ta.BeamwidthDeg, ta.FrontToBackDb, ta.ElevationFloorDb, txCF.UpVector, txCF.LookVector, dir)
	local ra = rxAntenna
	local rxGain = RFMath.AntennaGainDbi(ra.Pattern, ra.GainDbi, ra.BeamwidthDeg, ra.FrontToBackDb, ra.ElevationFloorDb, rxCF.UpVector, rxCF.LookVector, -dir)
	local polarization = RFMath.PolarizationLossDb(ta.Polarization, antennaAxis(txCF, ta.Polarization), ra.Polarization, antennaAxis(rxCF, ra.Polarization), dir, 20)
	local weather = environment:GetPathWeatherLossDb(frequencyMHz, dMeters)

	local shadow, fast, jitter = 0, 0, 0
	if not options.Deterministic then
		shadow, fast, jitter = computeFading(losses.Class, txRecord, rxRecord, txPos, rxPos, frequencyMHz, emitter.Stability, options.FadeState)
	end

	local eirp = emitter.TxPowerDbm + txGain
	local totalLoss = basic + losses.ExcessDb + weather + polarization
	local received = eirp + rxGain - totalLoss + shadow + fast + jitter

	out.HeightTx = hTx
	out.HeightRx = hRx
	out.Basic = basic
	out.Fspl = fspl
	out.PlaneEarth = planeEarth
	out.BasicModel = model
	out.TxGain = txGain
	out.RxGain = rxGain
	out.Polarization = polarization
	out.Weather = weather
	out.Shadow = shadow
	out.Fast = fast
	out.Jitter = jitter
	out.Eirp = eirp
	out.TotalLoss = totalLoss - shadow - fast - jitter
	out.Received = received
	return out
end

-- Generic received power of one emitter at an arbitrary receiving point.
function RF:ComputeReceivedPower(txRecord: DeviceRecord, emitterIndex: number, rxPosition: Vector3, rxCFrame: CFrame?, rxAntenna, options)
	local emitter = txRecord.Emitters[emitterIndex or 1]
	if not emitter then
		return -math.huge, nil
	end
	local cf = rxCFrame or CFrame.new(rxPosition)
	local antenna = rxAntenna
		or { Pattern = "Isotropic", GainDbi = 0, BeamwidthDeg = 360, FrontToBackDb = 0, ElevationFloorDb = 0, Polarization = "Vertical", HeightOffsetStuds = 0 }
	local breakdown = propagate(txRecord, emitter, nil, rxPosition, cf, antenna, emitter.FrequencyMHz, options or {})
	return breakdown.Received or -math.huge, breakdown
end

-- Quick estimate without terrain (used to rank interferers before detailed analysis).
local function estimateReceived(entry, rxPos: Vector3, rxAntenna): number
	local mps = config.Units.MetersPerStud
	local record = entry.Record
	local emitter = entry.Emitter
	local d = math.max((rxPos - record.Position).Magnitude * mps * config.Units.RangeScale, 1)
	local hTx = math.max(emitter.Antenna.HeightOffsetStuds * mps, 0.5)
	local hRx = math.max(rxAntenna.HeightOffsetStuds * mps, 0.5)
	local basic = RFMath.BasicTransmissionLossDb(d, hTx, hRx, emitter.FrequencyMHz)
	return emitter.TxPowerDbm + emitter.Antenna.GainDbi + rxAntenna.GainDbi - basic
end

function RF:ComputeInterferenceDbm(receiver, rxRecord: DeviceRecord?, rxPos: Vector3, rxCF: CFrame, excludeEmitterId: string?, options)
	options = options or {}
	local I = config.Interference
	if not I.Enabled or activeCount == 0 then
		return -math.huge, 0, {}
	end
	stats.InterferenceEvaluations += 1
	local couplingOptions = {
		AdjacentChannelRejectionDb = I.AdjacentChannelRejectionDb,
		AdjacentChannelSpan = I.AdjacentChannelSpan,
		MinUsefulOverlap = I.MinUsefulOverlap,
	}
	local candidates = {}
	local maxRange = I.MaxCandidateRangeStuds
	for _, entry in pairs(activeEmissions) do
		local record = entry.Record
		local emitter = entry.Emitter
		if emitter.Id ~= excludeEmitterId and record ~= rxRecord and record.InWorld then
			if (record.Position - rxPos).Magnitude <= maxRange then
				local _, coupling = SignalCompatibility.EnergyCoupling(emitter.FrequencyMHz, emitter.BandwidthKHz, receiver.FrequencyMHz, receiver.BandwidthKHz, couplingOptions)
				if coupling < math.huge then
					local duty = 10 * math.log10(math.max(emitter.DutyCycle, 1e-6))
					local estimate = estimateReceived(entry, rxPos, receiver.Antenna) - coupling + duty
					table.insert(candidates, { Entry = entry, Coupling = coupling, Duty = duty, Estimate = estimate })
				end
			end
		end
	end
	if #candidates == 0 then
		return -math.huge, 0, {}
	end
	table.sort(candidates, function(a, b)
		return a.Estimate > b.Estimate
	end)
	local profile = context.Scheduler:GetProfile()
	local detailed = math.min(I.MaxDetailedInterferers, profile.MaxDetailedInterferers)
	local totalLinear = 0
	local contributions = {}
	for i, c in ipairs(candidates) do
		local power = c.Estimate
		local mode = "Estimate"
		if i <= detailed then
			local breakdown = propagate(c.Entry.Record, c.Entry.Emitter, rxRecord, rxPos, rxCF, receiver.Antenna, c.Entry.Emitter.FrequencyMHz, {
				Force = options.Force,
				Deterministic = options.Deterministic,
				Priority = 3,
			})
			if breakdown.Received then
				power = breakdown.Received - c.Coupling + c.Duty
				mode = "Detailed"
			end
		end
		power -= receiver.InterferenceRejectionDb
		totalLinear += RFMath.DbToLinear(power)
		if i <= 8 then
			table.insert(contributions, { EmitterId = c.Entry.Emitter.Id, DeviceId = c.Entry.Record.Id, PowerDbm = power, Mode = mode })
		end
	end
	return RFMath.LinearToDb(totalLinear), #candidates, contributions
end

--------------------------------------------------------------------------------
-- Link evaluation
--------------------------------------------------------------------------------

local function emptyCompatibility(): Types.CompatibilityResult
	return {
		FrequencyOffsetMHz = 0,
		OverlapFraction = 0,
		CouplingLossDb = math.huge,
		InBand = false,
		ModulationMatch = false,
		NetworkMatch = false,
		SecurityMatch = false,
		Intelligible = false,
		Reasons = {},
	}
end

function RF:EvaluateLink(txRecord: DeviceRecord, rxRecord: DeviceRecord, options): LinkResult
	options = options or {}
	local t0 = os.clock()
	stats.Evaluations += 1
	if options.Force then
		stats.ForcedEvaluations += 1
	end
	if options.RefreshPose then
		registry:RefreshPose(txRecord)
		registry:RefreshPose(rxRecord)
	end
	local emitter = txRecord.Emitters[options.EmitterIndex or 1]
	local receiver = rxRecord.Receivers[options.ReceiverIndex or 1]
	local reasons = {}
	local previous: LinkResult? = options.Previous

	local result: any = {
		TxDeviceId = txRecord.Id,
		RxDeviceId = rxRecord.Id,
		EmitterId = emitter and emitter.Id or "",
		ReceiverId = receiver and receiver.Id or "",
		FrequencyMHz = emitter and emitter.FrequencyMHz or 0,
		DistanceStuds = (rxRecord.Position - txRecord.Position).Magnitude,
		DistanceMeters = (rxRecord.Position - txRecord.Position).Magnitude * config.Units.MetersPerStud,
		TxActive = false,
		EirpDbm = -math.huge,
		TxPowerDbm = emitter and emitter.TxPowerDbm or -math.huge,
		TxGainDbi = 0,
		RxGainDbi = 0,
		PolarizationLossDb = 0,
		FsplDb = 0,
		PlaneEarthDb = 0,
		BasicLossDb = 0,
		BasicModel = "None",
		EffectiveHeightTxM = 0,
		EffectiveHeightRxM = 0,
		Propagation = nil,
		WeatherLossDb = 0,
		ShadowFadingDb = 0,
		FastFadingDb = 0,
		EquipmentJitterDb = 0,
		TotalPathLossDb = math.huge,
		ReceivedPowerDbm = -math.huge,
		InBandSignalDbm = -math.huge,
		NoiseFloorDbm = 0,
		ExternalNoiseFigureDb = 0,
		InterferenceDbm = -math.huge,
		InterfererCount = 0,
		SnrDb = -math.huge,
		SinrDb = -math.huge,
		Compatibility = emptyCompatibility(),
		Quality = nil,
		AnalysisMode = "Deferred",
		Stale = false,
		Timestamp = os.clock(),
		Reasons = reasons,
	}

	local function finish(state: string?)
		local powered = txRecord.PowerState == "On" and rxRecord.PowerState == "On"
		if state then
			result.Quality = {
				State = state,
				Score = 0,
				MarginDb = -math.huge,
				SmoothedMarginDb = if previous and previous.Quality then previous.Quality.SmoothedMarginDb else -20,
				PacketLoss = 1,
				NoiseLevel = 1,
				DropoutRate = 1,
				Readability = 1,
				Strength = 1,
			}
		else
			result.Quality = qualityService:Evaluate({
				SinrDb = result.SinrDb,
				RequiredSinrDb = receiver.RequiredSinrDb,
				ReceivedPowerDbm = result.InBandSignalDbm,
				SensitivityDbm = receiver.SensitivityDbm,
				Compatible = result.Compatibility.Intelligible,
				Powered = powered,
				Previous = previous and previous.Quality or nil,
			})
		end
		local ms = (os.clock() - t0) * 1000
		stats.EvaluationMsAvg = stats.EvaluationMsAvg * 0.95 + ms * 0.05
		if ms > stats.EvaluationMsMax then
			stats.EvaluationMsMax = ms
		end
		return result :: LinkResult
	end

	if not emitter then
		table.insert(reasons, "NO_EMITTER")
		return finish("NoSignal")
	end
	if not receiver then
		table.insert(reasons, "NO_RECEIVER")
		return finish("NoSignal")
	end
	if txRecord.PowerState ~= "On" then
		table.insert(reasons, "TX_" .. string.upper(txRecord.PowerState))
	end
	if rxRecord.PowerState ~= "On" then
		table.insert(reasons, "RX_" .. string.upper(rxRecord.PowerState))
	end
	if not txRecord.InWorld or not rxRecord.InWorld then
		table.insert(reasons, "NOT_IN_WORLD")
		return finish("Offline")
	end
	result.TxActive = txRecord.PowerState == "On" and emitter.Transmitting

	local compatibility = SignalCompatibility.Evaluate(emitter, receiver, {
		AdjacentChannelRejectionDb = config.Interference.AdjacentChannelRejectionDb,
		AdjacentChannelSpan = config.Interference.AdjacentChannelSpan,
		MinUsefulOverlap = config.Interference.MinUsefulOverlap,
	})
	result.Compatibility = compatibility
	for _, r in ipairs(compatibility.Reasons) do
		table.insert(reasons, r)
	end

	local breakdown = propagate(txRecord, emitter, rxRecord, rxRecord.Position, rxRecord.AntennaCFrame, receiver.Antenna, emitter.FrequencyMHz, {
		Force = options.Force,
		Deterministic = options.Deterministic,
		Priority = options.Priority,
		FadeState = options.FadeState,
	})
	result.AnalysisMode = breakdown.AnalysisMode
	if breakdown.Losses == nil then
		stats.DeferredEvaluations += 1
		table.insert(reasons, "ANALYSIS_DEFERRED")
		if previous then
			-- Keep the last authoritative answer instead of inventing a new one.
			local copy = table.clone(previous)
			copy.Stale = true
			copy.AnalysisMode = "Cached"
			copy.Timestamp = previous.Timestamp
			copy.Reasons = table.clone(previous.Reasons)
			table.insert(copy.Reasons, "ANALYSIS_DEFERRED")
			return copy
		end
		return finish("NoSignal")
	end

	result.Stale = breakdown.Stale
	result.Propagation = breakdown.Losses
	result.DistanceStuds = breakdown.DistanceStuds
	result.DistanceMeters = breakdown.DistanceMeters
	result.EirpDbm = breakdown.Eirp
	result.TxGainDbi = breakdown.TxGain
	result.RxGainDbi = breakdown.RxGain
	result.PolarizationLossDb = breakdown.Polarization
	result.FsplDb = breakdown.Fspl
	result.PlaneEarthDb = breakdown.PlaneEarth
	result.BasicLossDb = breakdown.Basic
	result.BasicModel = breakdown.BasicModel
	result.EffectiveHeightTxM = breakdown.HeightTx
	result.EffectiveHeightRxM = breakdown.HeightRx
	result.WeatherLossDb = breakdown.Weather
	result.ShadowFadingDb = breakdown.Shadow
	result.FastFadingDb = breakdown.Fast
	result.EquipmentJitterDb = breakdown.Jitter
	result.TotalPathLossDb = breakdown.TotalLoss
	result.ReceivedPowerDbm = breakdown.Received
	result.InBandSignalDbm = if compatibility.CouplingLossDb < math.huge then breakdown.Received - compatibility.CouplingLossDb else -math.huge

	local fa = environment:GetExternalNoiseFigureDb(rxRecord.Position, receiver.FrequencyMHz)
	result.ExternalNoiseFigureDb = fa
	result.NoiseFloorDbm = RFMath.SystemNoiseFloorDbm(receiver.BandwidthKHz * 1000, receiver.NoiseFigureDb, fa)

	local includeInterference = options.IncludeInterference ~= false
	if includeInterference then
		local i, count = self:ComputeInterferenceDbm(receiver, rxRecord, rxRecord.Position, rxRecord.AntennaCFrame, emitter.Id, {
			Force = options.Force,
			Deterministic = options.Deterministic,
		})
		result.InterferenceDbm = i
		result.InterfererCount = count
		if count > 0 then
			table.insert(reasons, string.format("INTERFERENCE:%d", count))
		end
	end
	local noisePlusInterference = RFMath.PowerSumDbm(result.NoiseFloorDbm, result.InterferenceDbm)
	result.SnrDb = result.InBandSignalDbm - result.NoiseFloorDbm
	result.SinrDb = result.InBandSignalDbm - noisePlusInterference
	if breakdown.Stale then
		table.insert(reasons, "APPROXIMATE_ANALYSIS")
	end
	return finish(nil)
end

--------------------------------------------------------------------------------
-- Watched links (scheduler driven)
--------------------------------------------------------------------------------

function RF:WatchLink(txId: string, rxId: string, options): string?
	options = options or {}
	local tx = registry:GetDevice(txId)
	local rx = registry:GetDevice(rxId)
	if not tx or not rx then
		return nil
	end
	nextWatchNumber += 1
	local id = SharedUtilities.ShortId("LINK", nextWatchNumber)
	local watch: Watch = {
		Id = id,
		TxId = txId,
		RxId = rxId,
		EmitterIndex = options.EmitterIndex or 1,
		ReceiverIndex = options.ReceiverIndex or 1,
		Priority = math.clamp(options.Priority or 2, 1, 3),
		Label = options.Label or (tx.DisplayName .. " -> " .. rx.DisplayName),
		IncludeInterference = options.IncludeInterference ~= false,
		Deterministic = options.Deterministic == true,
		NextDue = 0,
		LastTxPos = nil,
		LastRxPos = nil,
		LastResult = nil,
		FadeState = newFadeState(nextWatchNumber * 7919),
		Evaluations = 0,
		CreatedAt = os.clock(),
	}
	watches[id] = watch
	table.insert(watchList, watch)
	return id
end

function RF:UnwatchLink(id: string, reason: string?)
	local watch = watches[id]
	if not watch then
		return
	end
	watches[id] = nil
	local index = table.find(watchList, watch)
	if index then
		table.remove(watchList, index)
	end
	RF.LinkRemoved:Fire(id, reason or "Unwatched")
end

function RF:GetWatch(id: string)
	return watches[id]
end

function RF:GetWatches()
	return watchList
end

function RF:EvaluateWatch(watch: Watch, force: boolean?)
	local tx = registry:GetDevice(watch.TxId)
	local rx = registry:GetDevice(watch.RxId)
	if not tx or not rx then
		self:UnwatchLink(watch.Id, "DeviceUnregistered")
		return nil
	end
	local result = self:EvaluateLink(tx, rx, {
		EmitterIndex = watch.EmitterIndex,
		ReceiverIndex = watch.ReceiverIndex,
		Priority = watch.Priority,
		Force = force,
		Deterministic = watch.Deterministic,
		IncludeInterference = watch.IncludeInterference,
		Previous = watch.LastResult,
		FadeState = watch.FadeState,
	})
	watch.Evaluations += 1
	stats.WatchEvaluations += 1
	watch.LastTxPos = tx.Position
	watch.LastRxPos = rx.Position
	local deferred = result.AnalysisMode == "Deferred" and watch.LastResult == nil
	if not deferred then
		watch.LastResult = result
		RF.LinkUpdated:Fire(watch.Id, result)
	end
	local profile = context.Scheduler:GetProfile()
	local interval = config.Scheduler.LinkIntervals[watch.Priority] * profile.LinkIntervalMultiplier
	-- Retry deferred analyses on the next frames instead of waiting a full interval.
	local retrySoon = result.AnalysisMode == "Deferred" or (result.AnalysisMode == "Cached" and result.Stale)
	watch.NextDue = os.clock() + (if retrySoon then 0.05 else interval)
	return result
end

local function isDue(watch: Watch, now: number): boolean
	if now >= watch.NextDue then
		return true
	end
	local tx = registry:GetDevice(watch.TxId)
	local rx = registry:GetDevice(watch.RxId)
	local threshold = config.Scheduler.LinkMoveThresholdStuds
	if tx and watch.LastTxPos and (tx.Position - watch.LastTxPos).Magnitude > threshold then
		return true
	end
	if rx and watch.LastRxPos and (rx.Position - watch.LastRxPos).Magnitude > threshold then
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function RF:Init(ctx)
	context = ctx
	config = ctx.Config
	registry = ctx.Registry
	terrainService = ctx.Terrain
	qualityService = ctx.Quality
	environment = ctx.Environment
end

function RF:Start()
	registry.DeviceRegistered:Connect(refreshActive)
	registry.DeviceChanged:Connect(function(record, kind)
		if kind == "Emission" or kind == "Configuration" or kind == "Pose" then
			refreshActive(record)
		end
	end)
	registry.DeviceUnregistered:Connect(function(record)
		removeAllFor(record)
		for i = #watchList, 1, -1 do
			local watch = watchList[i]
			if watch.TxId == record.Id or watch.RxId == record.Id then
				self:UnwatchLink(watch.Id, "DeviceUnregistered")
			end
		end
	end)
	context.Power.PowerStateChanged:Connect(function(record)
		refreshActive(record)
	end)
	for _, record in ipairs(registry:GetDeviceList()) do
		refreshActive(record)
	end

	context.Scheduler:AddJob("LinkEvaluation", 0, 3, function(_, budget)
		local count = #watchList
		if count == 0 then
			return
		end
		local deadline = os.clock() + budget * 0.85
		local now = os.clock()
		local visited = 0
		while visited < count and os.clock() < deadline do
			if watchCursor > #watchList then
				watchCursor = 1
			end
			local watch = watchList[watchCursor]
			watchCursor += 1
			visited += 1
			if watch and isDue(watch, now) then
				self:EvaluateWatch(watch, false)
			end
		end
	end)

	-- InWorld can change without an event (tool owner died, etc.); re-check lazily.
	context.Scheduler:AddJob("EmissionAudit", 2, 7, function()
		for _, record in ipairs(registry:GetDeviceList()) do
			refreshActive(record)
		end
	end)
end

function RF:GetStats()
	local out = table.clone(stats)
	out.ActiveEmissions = activeCount
	out.WatchedLinks = #watchList
	return out
end

return RF
