--!strict
--[[
	RFMath
	Pure, side-effect-free RF math used by the server simulation (and safe to use
	on the client for presentation). No Roblox world access happens here, which
	keeps every equation independently testable.

	Models implemented (simplified, documented, game-simulated):
	  * Free-space path loss (Friis)              FSPL = 20log10(d_km) + 20log10(f_MHz) + 32.45
	  * Plane-earth (two-ray) loss                L = 40log10(d_m) - 20log10(ht_m) - 20log10(hr_m)
	  * Single knife-edge diffraction, ITU-R P.526 J(v) approximation
	        J(v) = 6.9 + 20log10( sqrt((v-0.1)^2 + 1) + v - 0.1 )   for v > -0.78, else 0
	  * Multiple edges: Deygout construction with transition weighting T = 1 - exp(-J(vp)/6)
	  * Thermal noise kTB (-174 dBm/Hz at 290 K) and ITU-R P.372 man-made noise curves
	  * Weissberger vegetation loss
	  * ITU-R P.838-3 rain specific attenuation (tabulated coefficients, interpolated)
	  * Dipole-like elevation pattern and parabolic directional main lobe
	  * Linear polarization mismatch loss
	  * Rician / Rayleigh small-scale fading power gain from Gaussian components

	Nothing here models exact multipath, reflection ray tracing, or real waveforms.
]]

local RFMath = {}

local SPEED_OF_LIGHT = 299792458
local EARTH_RADIUS_M = 6371000
local LOG10 = math.log10
local SQRT = math.sqrt
local EXP = math.exp

RFMath.THERMAL_NOISE_DBM_PER_HZ = -174.0
RFMath.KNIFE_EDGE_V_THRESHOLD = -0.78

function RFMath.Clamp(x: number, lo: number, hi: number): number
	if x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
end

function RFMath.Lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function RFMath.WavelengthMeters(frequencyMHz: number): number
	return SPEED_OF_LIGHT / (math.max(frequencyMHz, 1e-6) * 1e6)
end

function RFMath.DbToLinear(db: number): number
	return 10 ^ (db / 10)
end

function RFMath.LinearToDb(x: number): number
	return 10 * LOG10(math.max(x, 1e-30))
end

-- Sum two powers given in dBm (incoherent power addition).
function RFMath.PowerSumDbm(a: number, b: number): number
	if a == -math.huge then
		return b
	elseif b == -math.huge then
		return a
	end
	return RFMath.LinearToDb(RFMath.DbToLinear(a) + RFMath.DbToLinear(b))
end

-- Combine two ALTERNATIVE propagation paths given their losses (dB). The received
-- power is the incoherent sum of both contributions, so the lower-loss path
-- dominates and two equal paths give 3 dB less loss than either alone.
function RFMath.ParallelLossDb(l1: number, l2: number): number
	local p = 10 ^ (-l1 / 10) + 10 ^ (-l2 / 10)
	return -10 * LOG10(math.max(p, 1e-30))
end

-- Power average of several losses (used for Fresnel spindle sampling).
function RFMath.PowerAverageLossDb(losses: { number }, weights: { number }?): number
	local sum, wsum = 0, 0
	for i, l in ipairs(losses) do
		local w = if weights then (weights[i] or 1) else 1
		sum += w * 10 ^ (-l / 10)
		wsum += w
	end
	if wsum <= 0 then
		return 0
	end
	return -10 * LOG10(math.max(sum / wsum, 1e-30))
end

function RFMath.FreeSpacePathLossDb(distanceMeters: number, frequencyMHz: number): number
	local dKm = math.max(distanceMeters, 1) / 1000
	return 20 * LOG10(dKm) + 20 * LOG10(math.max(frequencyMHz, 1e-3)) + 32.45
end

function RFMath.PlaneEarthLossDb(distanceMeters: number, txHeightM: number, rxHeightM: number): number
	local d = math.max(distanceMeters, 1)
	return 40 * LOG10(d) - 20 * LOG10(math.max(txHeightM, 0.1)) - 20 * LOG10(math.max(rxHeightM, 0.1))
end

-- Distance beyond which the two-ray (plane-earth) regime applies.
function RFMath.TwoRayCrossoverMeters(txHeightM: number, rxHeightM: number, frequencyMHz: number): number
	return 4 * math.pi * txHeightM * rxHeightM / RFMath.WavelengthMeters(frequencyMHz)
end

-- Basic transmission loss: free space inside the crossover distance, the larger of
-- free-space and plane-earth beyond it (plane-earth is only valid there).
function RFMath.BasicTransmissionLossDb(
	distanceMeters: number,
	txHeightM: number,
	rxHeightM: number,
	frequencyMHz: number
): (number, number, number, string)
	local fspl = RFMath.FreeSpacePathLossDb(distanceMeters, frequencyMHz)
	local pe = RFMath.PlaneEarthLossDb(distanceMeters, txHeightM, rxHeightM)
	local crossover = RFMath.TwoRayCrossoverMeters(txHeightM, rxHeightM, frequencyMHz)
	if distanceMeters > crossover and pe > fspl then
		return pe, fspl, pe, "PlaneEarth"
	end
	return fspl, fspl, pe, "FreeSpace"
end

-- ITU-R P.526 approximation of the knife-edge diffraction loss J(v).
function RFMath.KnifeEdgeLossDb(v: number): number
	if v <= RFMath.KNIFE_EDGE_V_THRESHOLD then
		return 0
	end
	local a = v - 0.1
	return 6.9 + 20 * LOG10(SQRT(a * a + 1) + a)
end

-- Fresnel-Kirchhoff diffraction parameter for an obstacle h meters above the
-- line between the terminals (negative h = below the line).
function RFMath.FresnelParameter(hMeters: number, d1Meters: number, d2Meters: number, wavelengthM: number): number
	if d1Meters <= 0 or d2Meters <= 0 then
		return -math.huge
	end
	return hMeters * SQRT(2 * (d1Meters + d2Meters) / (wavelengthM * d1Meters * d2Meters))
end

function RFMath.FresnelRadiusMeters(d1Meters: number, d2Meters: number, wavelengthM: number, zone: number?): number
	local n = zone or 1
	if d1Meters <= 0 or d2Meters <= 0 then
		return 0
	end
	return SQRT(n * wavelengthM * d1Meters * d2Meters / (d1Meters + d2Meters))
end

function RFMath.EarthBulgeMeters(d1Meters: number, d2Meters: number, kFactor: number): number
	return d1Meters * d2Meters / (2 * kFactor * EARTH_RADIUS_M)
end

export type DeygoutResult = {
	LossDb: number,
	PrincipalV: number,
	PrincipalIndex: number?,
	Edges: number,
}

--[[
	Deygout multiple-edge diffraction over a sampled profile.
	distances[i]  : meters from terminal A
	heights[i]    : obstacle height (meters, same datum as terminal heights, earth bulge already added)
	excluded[i]   : true = never treated as an edge
	yA, yB        : antenna heights of the terminals (meters, same datum)
	totalD        : terminal separation (meters, horizontal)
	maxDepth      : 0 = principal edge only, 1 = principal + one secondary each side, ...
]]
function RFMath.DeygoutLossDb(
	distances: { number },
	heights: { number },
	excluded: { boolean }?,
	count: number,
	yA: number,
	yB: number,
	totalD: number,
	wavelengthM: number,
	maxDepth: number
): DeygoutResult
	local edges = 0

	local function principal(iStart: number, iEnd: number, dA: number, hA: number, dB: number, hB: number): (number?, number)
		local span = dB - dA
		if span <= 0 then
			return nil, -math.huge
		end
		local bestIndex: number? = nil
		local bestV = -math.huge
		for i = iStart, iEnd do
			if not (excluded and excluded[i]) then
				local d1 = distances[i] - dA
				local d2 = dB - distances[i]
				if d1 > 0 and d2 > 0 then
					local los = hA + (hB - hA) * (d1 / span)
					local v = (heights[i] - los) * SQRT(2 * span / (wavelengthM * d1 * d2))
					if v > bestV then
						bestV = v
						bestIndex = i
					end
				end
			end
		end
		return bestIndex, bestV
	end

	local function solve(iStart: number, iEnd: number, dA: number, hA: number, dB: number, hB: number, depth: number): (number, number, number?)
		if iEnd < iStart then
			return 0, -math.huge, nil
		end
		local p, v = principal(iStart, iEnd, dA, hA, dB, hB)
		if p == nil or v <= RFMath.KNIFE_EDGE_V_THRESHOLD then
			return 0, v, nil
		end
		local pIndex = p :: number
		edges += 1
		local lossP = RFMath.KnifeEdgeLossDb(v)
		if depth >= maxDepth then
			return lossP, v, pIndex
		end
		local lossT = solve(iStart, pIndex - 1, dA, hA, distances[pIndex], heights[pIndex], depth + 1)
		local lossR = solve(pIndex + 1, iEnd, distances[pIndex], heights[pIndex], dB, hB, depth + 1)
		local t = 1 - EXP(-lossP / 6)
		return lossP + t * (lossT + lossR), v, pIndex
	end

	local loss, v, index = solve(1, count, 0, yA, totalD, yB, 0)
	return {
		LossDb = loss,
		PrincipalV = v,
		PrincipalIndex = index,
		Edges = edges,
	}
end

function RFMath.ThermalNoiseDbm(bandwidthHz: number): number
	return RFMath.THERMAL_NOISE_DBM_PER_HZ + 10 * LOG10(math.max(bandwidthHz, 1))
end

-- ITU-R P.372 median man-made noise figure Fam (dB above kT0B).
function RFMath.ManMadeNoiseFigureDb(c: number, d: number, frequencyMHz: number): number
	return c - d * LOG10(math.max(frequencyMHz, 0.3))
end

-- Operating noise floor: kTB + total noise factor (external Fa plus receiver NF).
-- f_total = f_a + f_r - 1 (linear noise factors).
function RFMath.SystemNoiseFloorDbm(bandwidthHz: number, receiverNoiseFigureDb: number, externalNoiseFigureDb: number): number
	local fa = 10 ^ (externalNoiseFigureDb / 10)
	local fr = 10 ^ (receiverNoiseFigureDb / 10)
	local total = math.max(fa + fr - 1, 1)
	return RFMath.ThermalNoiseDbm(bandwidthHz) + 10 * LOG10(total)
end

-- Weissberger modified exponential decay model (f in GHz, depth in meters).
function RFMath.WeissbergerLossDb(depthMeters: number, frequencyGHz: number, minFrequencyGHz: number?): number
	if depthMeters <= 0 then
		return 0
	end
	local f = math.max(frequencyGHz, minFrequencyGHz or 0.03)
	local fTerm = f ^ 0.284
	if depthMeters < 14 then
		return 0.45 * fTerm * depthMeters
	end
	local d = math.min(depthMeters, 400)
	return 1.33 * fTerm * d ^ 0.588
end

-- ITU-R P.838-3 coefficients (horizontal polarization) at tabulated frequencies.
local RAIN_TABLE = {
	{ f = 1, k = 0.0000259, a = 0.9691 },
	{ f = 2, k = 0.0000847, a = 1.0664 },
	{ f = 4, k = 0.0001071, a = 1.6009 },
	{ f = 6, k = 0.0007056, a = 1.5900 },
	{ f = 7, k = 0.001915, a = 1.4810 },
	{ f = 8, k = 0.004115, a = 1.3905 },
	{ f = 10, k = 0.01217, a = 1.2571 },
	{ f = 12, k = 0.02386, a = 1.1825 },
	{ f = 15, k = 0.04481, a = 1.1233 },
	{ f = 20, k = 0.09164, a = 1.0568 },
	{ f = 25, k = 0.1571, a = 0.9991 },
	{ f = 30, k = 0.2403, a = 0.9485 },
	{ f = 35, k = 0.3374, a = 0.9047 },
	{ f = 40, k = 0.4431, a = 0.8673 },
}

-- Rain specific attenuation in dB/km (approximate, interpolated in log-frequency).
function RFMath.RainSpecificAttenuationDbPerKm(frequencyGHz: number, rainRateMmH: number): number
	if rainRateMmH <= 0 or frequencyGHz < 1 then
		return 0
	end
	local f = math.min(frequencyGHz, 40)
	local lower = RAIN_TABLE[1]
	local upper = RAIN_TABLE[#RAIN_TABLE]
	for i = 1, #RAIN_TABLE - 1 do
		if f >= RAIN_TABLE[i].f and f <= RAIN_TABLE[i + 1].f then
			lower = RAIN_TABLE[i]
			upper = RAIN_TABLE[i + 1]
			break
		end
	end
	local t = 0
	if upper.f > lower.f then
		t = (LOG10(f) - LOG10(lower.f)) / (LOG10(upper.f) - LOG10(lower.f))
	end
	local logK = LOG10(lower.k) + (LOG10(upper.k) - LOG10(lower.k)) * t
	local alpha = lower.a + (upper.a - lower.a) * t
	return (10 ^ logK) * rainRateMmH ^ alpha
end

-- Approximate cloud/fog liquid-water specific attenuation (dB/km per g/m^3).
-- Rough f^2 fit, only meaningful above ~10 GHz.
function RFMath.FogSpecificCoefficient(frequencyGHz: number): number
	if frequencyGHz < 3 then
		return 0
	end
	return 0.0004 * frequencyGHz ^ 1.95
end

--[[
	Antenna gain toward a direction.
	axis      : antenna element axis (UpVector of the antenna frame) for Omni patterns
	boresight : main-lobe direction (LookVector of the antenna frame) for Directional patterns
	toTarget  : unit vector from the antenna to the far terminal
]]
function RFMath.AntennaGainDbi(
	pattern: string,
	gainDbi: number,
	beamwidthDeg: number,
	frontToBackDb: number,
	elevationFloorDb: number,
	axis: Vector3,
	boresight: Vector3,
	toTarget: Vector3
): (number, number)
	if pattern == "Isotropic" then
		return gainDbi, 0
	elseif pattern == "Directional" then
		local c = RFMath.Clamp(boresight:Dot(toTarget), -1, 1)
		local offDeg = math.deg(math.acos(c))
		local bw = math.max(beamwidthDeg, 1)
		local attenuation = math.min(12 * (offDeg / bw) ^ 2, frontToBackDb)
		return gainDbi - attenuation, offDeg
	end
	-- Omni: dipole-like doughnut, gain proportional to sin^2(angle from the element axis).
	local cosAxis = RFMath.Clamp(axis:Dot(toTarget), -1, 1)
	local sin2 = 1 - cosAxis * cosAxis
	local floorLinear = 10 ^ (-math.abs(elevationFloorDb) / 10)
	local elevationDeg = 90 - math.deg(math.acos(math.abs(cosAxis)))
	return gainDbi + 10 * LOG10(math.max(sin2, floorLinear)), elevationDeg
end

-- Polarization mismatch between two antennas for a given propagation direction.
function RFMath.PolarizationLossDb(
	polA: string,
	axisA: Vector3,
	polB: string,
	axisB: Vector3,
	propagation: Vector3,
	maxLossDb: number
): number
	local circularA = polA == "Circular"
	local circularB = polB == "Circular"
	if circularA and circularB then
		return 0
	elseif circularA or circularB then
		return 3
	end
	-- Project each element axis onto the plane perpendicular to the propagation direction.
	local pa = axisA - propagation * axisA:Dot(propagation)
	local pb = axisB - propagation * axisB:Dot(propagation)
	local ma, mb = pa.Magnitude, pb.Magnitude
	if ma < 1e-3 or mb < 1e-3 then
		-- Looking straight down an element: the pattern null already models this.
		return 0
	end
	local c = math.abs((pa / ma):Dot(pb / mb))
	if c < 1e-4 then
		return maxLossDb
	end
	return math.min(-20 * LOG10(c), maxLossDb)
end

-- Rician fading power gain (dB) from two unit Gaussian components and a K-factor.
-- K = 0 reduces to Rayleigh. Mean linear power gain is 1.
function RFMath.RicianPowerGainDb(g1: number, g2: number, kFactor: number, floorDb: number): number
	local k = math.max(kFactor, 0)
	local los = SQRT(k / (k + 1))
	local scatter = SQRT(1 / (k + 1)) / SQRT(2)
	local i = los + scatter * g1
	local q = scatter * g2
	local p = i * i + q * q
	return math.max(10 * LOG10(math.max(p, 1e-12)), floorDb)
end

-- Fraction of an emitter's power that falls inside a receiver passband, assuming a
-- flat emission spectrum across its bandwidth.
function RFMath.BandOverlapFraction(emitterMHz: number, emitterBwKHz: number, receiverMHz: number, receiverBwKHz: number): number
	local eHalf = math.max(emitterBwKHz, 0.001) / 2000
	local rHalf = math.max(receiverBwKHz, 0.001) / 2000
	local lo = math.max(emitterMHz - eHalf, receiverMHz - rHalf)
	local hi = math.min(emitterMHz + eHalf, receiverMHz + rHalf)
	if hi <= lo then
		return 0
	end
	return (hi - lo) / (2 * eHalf)
end

-- Smooth logistic helper used by quality mapping.
function RFMath.Logistic(x: number, midpoint: number, slope: number): number
	return 1 / (1 + EXP(-slope * (x - midpoint)))
end

-- 32-bit wrapping multiply that never exceeds double precision (b < 2^32).
local function mul32(a: number, b: number): number
	local x = bit32.band(a, 0xFFFFFFFF)
	local lo = bit32.band(x, 0xFFFF)
	local hi = bit32.rshift(x, 16)
	return bit32.band(lo * b + bit32.band(hi * b, 0xFFFF) * 65536, 0xFFFFFFFF)
end

-- Deterministic integer hash (murmur3-style finalizer) -> [0, 1).
function RFMath.Hash01(a: number, b: number, c: number): number
	local h = mul32(bit32.band(a, 0xFFFFFFFF), 0x85EBCA6B)
	h = bit32.bxor(h, mul32(bit32.band(b, 0xFFFFFFFF), 0xC2B2AE35))
	h = bit32.bxor(h, mul32(bit32.band(c, 0xFFFFFFFF), 0x27D4EB2F))
	h = bit32.bxor(h, bit32.rshift(h, 16))
	h = mul32(h, 0x85EBCA6B)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	h = mul32(h, 0xC2B2AE35)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return h / 4294967296
end

-- Deterministic standard-normal value from integer lattice coordinates (Box-Muller).
function RFMath.HashGaussian(a: number, b: number, c: number): number
	local u1 = math.max(RFMath.Hash01(a, b, c), 1e-9)
	local u2 = RFMath.Hash01(a + 7919, b - 104729, c + 1299709)
	return SQRT(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

-- Smooth 2D value noise with unit-variance Gaussian lattice values.
-- Used for spatially correlated shadow fading (same place => same value).
function RFMath.GaussianValueNoise2D(x: number, z: number, cellSize: number, seed: number): number
	local gx, gz = x / cellSize, z / cellSize
	local x0, z0 = math.floor(gx), math.floor(gz)
	local tx, tz = gx - x0, gz - z0
	-- smoothstep weights
	tx = tx * tx * (3 - 2 * tx)
	tz = tz * tz * (3 - 2 * tz)
	local v00 = RFMath.HashGaussian(x0, z0, seed)
	local v10 = RFMath.HashGaussian(x0 + 1, z0, seed)
	local v01 = RFMath.HashGaussian(x0, z0 + 1, seed)
	local v11 = RFMath.HashGaussian(x0 + 1, z0 + 1, seed)
	local a = v00 + (v10 - v00) * tx
	local b = v01 + (v11 - v01) * tx
	-- Bilinear blending reduces variance between lattice points; renormalize.
	local w00 = (1 - tx) * (1 - tz)
	local w10 = tx * (1 - tz)
	local w01 = (1 - tx) * tz
	local w11 = tx * tz
	local norm = SQRT(w00 * w00 + w10 * w10 + w01 * w01 + w11 * w11)
	return (a + (b - a) * tz) / math.max(norm, 1e-6)
end

return RFMath
