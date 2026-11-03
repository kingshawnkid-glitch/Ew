--[[
	SignalQualityService
	Maps a computed link budget to a player-facing quality state. Presentation
	layers (radio audio, text traffic, data links) consume QualityResult and never
	recompute RF themselves.

	margin = SINR - RequiredSinr(receiver profile)

	State (with hysteresis so a link hovering on a threshold does not flicker):
	  Clear     margin >= 15 dB   clear voice / data
	  Good      margin >=  8 dB   minor hiss
	  Degraded  margin >=  3 dB   occasional noise / dropouts
	  Broken    margin >= -1 dB   distorted, interrupted, partial messages
	  Unusable  margin <  -1 dB   incomplete / unintelligible
	  NoSignal  received power far below sensitivity, or margin < -10 dB
	  Incompatible  energy present but wrong mode / network / security / frequency
	  Offline   transmitter or receiver not powered

	Derived presentation values (all 0..1 unless noted):
	  Score, PacketLoss, NoiseLevel, DropoutRate, Readability (1..5), Strength (1..5)
	Readability/Strength follow the familiar radio-check "loud and clear" scale.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("EWShared")
local RFMath = require(Shared.RFMath)

local SignalQualityService = {}

local config
local ORDER = { "Clear", "Good", "Degraded", "Broken", "Unusable" }
local RANK = { Clear = 1, Good = 2, Degraded = 3, Broken = 4, Unusable = 5 }

function SignalQualityService:Init(ctx)
	config = ctx.Config
end

local function thresholdFor(state: string): number?
	local t = config.Quality.Thresholds
	if state == "Clear" then
		return t.Clear
	elseif state == "Good" then
		return t.Good
	elseif state == "Degraded" then
		return t.Degraded
	elseif state == "Broken" then
		return t.Broken
	end
	return nil
end

-- Pure classification with optional hysteresis against the previous state.
function SignalQualityService:ClassifyMargin(margin: number, previousState: string?): string
	local h = config.Quality.HysteresisDb
	local raw = "Unusable"
	for _, state in ipairs(ORDER) do
		local threshold = thresholdFor(state)
		if threshold and margin >= threshold then
			raw = state
			break
		end
	end
	if previousState and RANK[previousState] and RANK[raw] and raw ~= previousState then
		-- Moving to a worse state requires dropping below the previous threshold by h;
		-- moving to a better state requires exceeding the new threshold by h.
		if RANK[raw] > RANK[previousState] then
			local prevThreshold = thresholdFor(previousState)
			if prevThreshold and margin > prevThreshold - h then
				return previousState
			end
		else
			local newThreshold = thresholdFor(raw)
			if newThreshold and margin < newThreshold + h then
				return previousState
			end
		end
	end
	return raw
end

--[[
	Evaluate(params) -> QualityResult
	params = {
	  SinrDb, RequiredSinrDb, ReceivedPowerDbm, SensitivityDbm,
	  Compatible: boolean, Powered: boolean,
	  Previous: QualityResult?   (for hysteresis and smoothing)
	}
]]
function SignalQualityService:Evaluate(params)
	local q = config.Quality
	local margin = params.SinrDb - params.RequiredSinrDb
	local previous = params.Previous
	local function finite(x: number?): boolean
		return x ~= nil and x == x and x ~= math.huge and x ~= -math.huge
	end
	local smoothed = margin
	if previous and finite(previous.SmoothedMarginDb) and finite(margin) then
		smoothed = previous.SmoothedMarginDb + (margin - previous.SmoothedMarginDb) * q.SmoothingAlpha
	end

	local state
	if not params.Powered then
		state = "Offline"
	elseif params.ReceivedPowerDbm < params.SensitivityDbm - q.SensitivityFloorMarginDb or margin < q.NoSignalMarginDb then
		state = "NoSignal"
	elseif not params.Compatible then
		state = "Incompatible"
	else
		state = self:ClassifyMargin(smoothed, previous and previous.State or nil)
	end

	local usable = state ~= "Offline" and state ~= "NoSignal" and state ~= "Incompatible"
	local score = if usable then RFMath.Logistic(margin, q.ScoreMidpointDb, q.ScoreSlope) else 0
	local packetLoss = if usable then 1 - RFMath.Logistic(margin, q.PacketLossMidpointDb, q.PacketLossSlope) else 1
	local noise = if usable then math.clamp(1 - RFMath.Logistic(margin, 10, 0.3), 0.02, 1) else 1
	local dropout = if usable then math.clamp(packetLoss * 0.8, 0, 1) else 1

	local readability = 1
	if usable then
		readability = math.clamp(math.floor(1 + score * 4.999), 1, 5)
	end
	local aboveSensitivity = params.ReceivedPowerDbm - params.SensitivityDbm
	local strength = math.clamp(math.floor(1 + math.clamp(aboveSensitivity, 0, 40) / 10), 1, 5)
	if params.ReceivedPowerDbm < params.SensitivityDbm then
		strength = 1
	end

	return {
		State = state,
		Score = score,
		MarginDb = margin,
		SmoothedMarginDb = smoothed,
		PacketLoss = packetLoss,
		NoiseLevel = noise,
		DropoutRate = dropout,
		Readability = readability,
		Strength = strength,
	}
end

return SignalQualityService
