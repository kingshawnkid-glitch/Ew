--!strict
--[[
	SignalCompatibility
	The single interface every system uses to decide how an emission relates to a
	receiver. It separates three questions that a naive system conflates:

	  1. ENERGY     - how much of the emitter's power lands in the receiver passband
	                  (co-channel, partial overlap, adjacent-channel leakage, none)
	  2. DEMODULATION - can the receiver's mode demodulate that waveform at all
	  3. AUTHORIZATION - simulated network membership and security profile

	Energy always counts toward interference even when (2) or (3) fail: an
	incompatible transmission on your frequency is still noise to you.

	Security profiles are SIMULATED strings, e.g. "PT" (plain text) or
	"CT:<keyId>" (cipher text with a key slot). No cryptography is performed;
	the server simply compares profiles it owns.
]]

local Types = require(script.Parent.EWTypes)
local RFMath = require(script.Parent.RFMath)

type Emitter = Types.Emitter
type Receiver = Types.Receiver
type CompatibilityResult = Types.CompatibilityResult

local SignalCompatibility = {}

-- Modulation families that a receiver mode can demodulate.
local DEMOD_FAMILIES: { [string]: { [string]: boolean } } = {
	FM = { FM = true },
	AM = { AM = true },
	PSK = { PSK = true },
	FSK = { FSK = true },
	OFDM = { OFDM = true },
	FHSS = { FHSS = true },
	DSSS = { DSSS = true },
	Pulse = { Pulse = true },
	CW = { CW = true, AM = true },
	Broadband = {},
	Noise = {},
}

export type CompatibilityOptions = {
	AdjacentChannelRejectionDb: number?,
	AdjacentChannelSpan: number?,
	MinUsefulOverlap: number?,
	IgnoreAuthorization: boolean?,
}

local function securityKind(profile: string?): (string, string?)
	if profile == nil or profile == "" then
		return "ANY", nil
	end
	if profile == "PT" then
		return "PT", nil
	end
	local key = string.match(profile, "^CT:(.+)$")
	if key then
		return "CT", key
	end
	return "OTHER", profile
end

-- True when a receiver configured with rxProfile can recover traffic sent with txProfile.
function SignalCompatibility.SecurityCompatible(txProfile: string?, rxProfile: string?): boolean
	local txKind, txKey = securityKind(txProfile)
	local rxKind, rxKey = securityKind(rxProfile)
	if txKind == "ANY" or rxKind == "ANY" then
		return true
	end
	if txKind == "PT" then
		-- Plain-text traffic is receivable by PT receivers; CT receivers in this
		-- simulation also pass PT audio (common radio behaviour, configurable later).
		return rxKind == "PT" or rxKind == "CT"
	end
	if txKind == "CT" then
		return rxKind == "CT" and txKey == rxKey
	end
	return txKey == rxKey
end

function SignalCompatibility.NetworkCompatible(txNetwork: string?, rxNetwork: string?): boolean
	if txNetwork == nil or rxNetwork == nil or txNetwork == "" or rxNetwork == "" then
		return true
	end
	return txNetwork == rxNetwork
end

function SignalCompatibility.ModulationCompatible(txModulation: string, rxModulation: string): boolean
	local family = DEMOD_FAMILIES[rxModulation]
	return family ~= nil and family[txModulation] == true
end

-- Energy coupling only (used for interference sums). Returns overlap fraction and
-- coupling loss in dB (math.huge when nothing couples).
function SignalCompatibility.EnergyCoupling(
	emitterMHz: number,
	emitterBwKHz: number,
	receiverMHz: number,
	receiverBwKHz: number,
	options: CompatibilityOptions?
): (number, number, boolean)
	local acr = (options and options.AdjacentChannelRejectionDb) or 60
	local span = (options and options.AdjacentChannelSpan) or 3
	local minOverlap = (options and options.MinUsefulOverlap) or 1e-4
	local overlap = RFMath.BandOverlapFraction(emitterMHz, emitterBwKHz, receiverMHz, receiverBwKHz)
	-- A wideband emission (barrage jammer) puts only a tiny share of its power in a
	-- narrow channel, but it is still in band when it covers the receiver passband.
	local passbandCovered = if overlap > 0
		then RFMath.BandOverlapFraction(receiverMHz, receiverBwKHz, emitterMHz, emitterBwKHz)
		else 0
	if overlap >= minOverlap or passbandCovered >= minOverlap then
		return overlap, -10 * math.log10(overlap), true
	end
	-- Not in band: adjacent-channel leakage if the emission edge is within `span`
	-- receiver bandwidths of the passband edge.
	local gapMHz = math.abs(emitterMHz - receiverMHz) - (emitterBwKHz + receiverBwKHz) / 2000
	local rxBwMHz = math.max(receiverBwKHz, 0.001) / 1000
	if gapMHz <= span * rxBwMHz then
		-- Leakage proportional to receiver bandwidth relative to emitter bandwidth.
		local share = math.min(1, receiverBwKHz / math.max(emitterBwKHz, 0.001))
		return 0, acr - 10 * math.log10(share), false
	end
	return 0, math.huge, false
end

function SignalCompatibility.Evaluate(emitter: Emitter, receiver: Receiver, options: CompatibilityOptions?): CompatibilityResult
	local reasons = {}
	local overlap, couplingLoss, inBand =
		SignalCompatibility.EnergyCoupling(emitter.FrequencyMHz, emitter.BandwidthKHz, receiver.FrequencyMHz, receiver.BandwidthKHz, options)

	local modulationMatch = SignalCompatibility.ModulationCompatible(emitter.Modulation, receiver.Modulation)
	local networkMatch = true
	local securityMatch = true
	if not (options and options.IgnoreAuthorization) then
		networkMatch = SignalCompatibility.NetworkCompatible(emitter.NetworkId, receiver.NetworkId)
		securityMatch = SignalCompatibility.SecurityCompatible(emitter.SecurityProfile, receiver.SecurityProfile)
	end

	if not inBand then
		table.insert(reasons, if couplingLoss == math.huge then "OFF_FREQUENCY" else "ADJACENT_CHANNEL_ONLY")
	elseif overlap < 0.5 then
		table.insert(reasons, "PARTIAL_BAND_OVERLAP")
	end
	if not modulationMatch then
		table.insert(reasons, "MODE_MISMATCH")
	end
	if not networkMatch then
		table.insert(reasons, "NETWORK_MISMATCH")
	end
	if not securityMatch then
		table.insert(reasons, "SECURITY_MISMATCH")
	end
	if not receiver.Enabled then
		table.insert(reasons, "RECEIVER_DISABLED")
	end

	local intelligible = inBand and overlap >= 0.5 and modulationMatch and networkMatch and securityMatch and receiver.Enabled

	return {
		FrequencyOffsetMHz = emitter.FrequencyMHz - receiver.FrequencyMHz,
		OverlapFraction = overlap,
		CouplingLossDb = couplingLoss,
		InBand = inBand,
		ModulationMatch = modulationMatch,
		NetworkMatch = networkMatch,
		SecurityMatch = securityMatch,
		Intelligible = intelligible,
		Reasons = reasons,
	}
end

return SignalCompatibility
