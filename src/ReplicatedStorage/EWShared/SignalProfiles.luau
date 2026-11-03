--!strict
--[[
	SignalProfiles
	Emission/reception profiles shared by every device. A device references a
	profile by Id (attribute "SignalProfile" or its DeviceDefinition default) and
	may override frequency, bandwidth and power with attributes.

	"Source" documents where each default came from:
	  * "Public datasheet" - unclassified, non-export-controlled manufacturer
	    datasheet values (e.g. L3Harris AN/PRC-163 datasheet L26821, 08/2024:
	    250 mW-5 W LOS, 10 W SATCOM, -116 dBm @ 36.5-52 MHz and -114 dBm @
	    146-426 MHz for 12 dB SINAD).
	  * "Game value" - gameplay-tuned simulation parameter, not a real figure.

	RequiredSinrDb is the pre-detection SINR the game treats as "minimally
	intelligible". For analog FM it is set so that NoiseFigure + RequiredSinr
	reproduces the datasheet 12 dB SINAD sensitivity in a 25 kHz channel.
	No real waveform, hopping pattern or cryptographic behaviour is modelled.
]]

local Types = require(script.Parent.EWTypes)

type SignalProfile = Types.SignalProfile
type AntennaSpec = Types.AntennaSpec

local function omni(gain: number, heightStuds: number, polarization: Types.Polarization?): AntennaSpec
	return {
		Pattern = "Omni",
		GainDbi = gain,
		BeamwidthDeg = 360,
		FrontToBackDb = 0,
		ElevationFloorDb = 15,
		Polarization = polarization or "Vertical",
		HeightOffsetStuds = heightStuds,
	}
end

local function directional(gain: number, beamwidth: number, ftb: number, heightStuds: number, polarization: Types.Polarization?): AntennaSpec
	return {
		Pattern = "Directional",
		GainDbi = gain,
		BeamwidthDeg = beamwidth,
		FrontToBackDb = ftb,
		ElevationFloorDb = 0,
		Polarization = polarization or "Vertical",
		HeightOffsetStuds = heightStuds,
	}
end

local function isotropic(gain: number, heightStuds: number): AntennaSpec
	return {
		Pattern = "Isotropic",
		GainDbi = gain,
		BeamwidthDeg = 360,
		FrontToBackDb = 0,
		ElevationFloorDb = 0,
		Polarization = "Vertical",
		HeightOffsetStuds = heightStuds,
	}
end

local Profiles: { [string]: SignalProfile } = {
	VHF_FM_VOICE = {
		Id = "VHF_FM_VOICE",
		DisplayName = "VHF-LOW FM voice (VULOS-style)",
		SignalType = "Voice",
		Modulation = "FM",
		DetectionClass = "Communications",
		Intentional = true,
		DefaultFrequencyMHz = 45.0,
		MinFrequencyMHz = 30.0,
		MaxFrequencyMHz = 88.0,
		BandwidthKHz = 25,
		TxPowerDbm = 37.0, -- 5 W (public datasheet maximum LOS power)
		PowerLevelsDbm = { LOW = 24.0, MED = 30.0, HIGH = 37.0 }, -- 0.25 W / 1 W / 5 W
		DutyCycle = 1.0,
		Antenna = omni(-2.0, 2.5), -- short whip on a body-worn handheld (game value)
		SensitivityDbm = -116, -- public datasheet (36.5-52 MHz, 12 dB SINAD)
		NoiseFigureDb = 9,
		RequiredSinrDb = 5,
		InterferenceRejectionDb = 0,
		Stability = 0.97,
		ContinuousEmission = false,
		Source = "Public datasheet (power, sensitivity); game value (antenna, thresholds)",
	},
	VHF_AM_VOICE = {
		Id = "VHF_AM_VOICE",
		DisplayName = "VHF-HIGH AM voice (air band)",
		SignalType = "Voice",
		Modulation = "AM",
		DetectionClass = "Communications",
		Intentional = true,
		DefaultFrequencyMHz = 142.5,
		MinFrequencyMHz = 118.0,
		MaxFrequencyMHz = 174.0,
		BandwidthKHz = 25,
		TxPowerDbm = 37.0,
		PowerLevelsDbm = { LOW = 24.0, MED = 30.0, HIGH = 37.0 },
		DutyCycle = 1.0,
		Antenna = omni(-1.0, 2.5),
		SensitivityDbm = -114, -- public datasheet (146-426 MHz band figure)
		NoiseFigureDb = 8,
		RequiredSinrDb = 9, -- AM needs more SNR than FM for the same readability (game value)
		InterferenceRejectionDb = 0,
		Stability = 0.97,
		ContinuousEmission = false,
		Source = "Public datasheet (power, sensitivity); game value (antenna, thresholds)",
	},
	UHF_FM_VOICE = {
		Id = "UHF_FM_VOICE",
		DisplayName = "UHF FM voice",
		SignalType = "Voice",
		Modulation = "FM",
		DetectionClass = "Communications",
		Intentional = true,
		DefaultFrequencyMHz = 300.0,
		MinFrequencyMHz = 225.0,
		MaxFrequencyMHz = 512.0,
		BandwidthKHz = 25,
		TxPowerDbm = 37.0,
		PowerLevelsDbm = { LOW = 24.0, MED = 30.0, HIGH = 37.0 },
		DutyCycle = 1.0,
		Antenna = omni(0.0, 2.5),
		SensitivityDbm = -114,
		NoiseFigureDb = 7,
		RequiredSinrDb = 5,
		InterferenceRejectionDb = 0,
		Stability = 0.97,
		ContinuousEmission = false,
		Source = "Public datasheet (power, sensitivity); game value (antenna, thresholds)",
	},
	UHF_DIGITAL_VOICE = {
		Id = "UHF_DIGITAL_VOICE",
		DisplayName = "UHF narrowband digital voice (simulated CT)",
		SignalType = "Voice",
		Modulation = "FSK",
		DetectionClass = "Communications",
		Intentional = true,
		DefaultFrequencyMHz = 310.0,
		MinFrequencyMHz = 225.0,
		MaxFrequencyMHz = 512.0,
		BandwidthKHz = 25,
		TxPowerDbm = 37.0,
		PowerLevelsDbm = { LOW = 24.0, MED = 30.0, HIGH = 37.0 },
		DutyCycle = 1.0,
		Antenna = omni(0.0, 2.5),
		SensitivityDbm = -116,
		NoiseFigureDb = 7,
		RequiredSinrDb = 7,
		InterferenceRejectionDb = 0,
		Stability = 0.98,
		ContinuousEmission = false,
		Source = "Game value",
	},
	MANET_DATA_UHF = {
		Id = "MANET_DATA_UHF",
		DisplayName = "UHF wideband MANET data (generic)",
		SignalType = "Data",
		Modulation = "OFDM",
		DetectionClass = "Communications",
		Intentional = true,
		DefaultFrequencyMHz = 400.0,
		MinFrequencyMHz = 225.0,
		MaxFrequencyMHz = 450.0,
		BandwidthKHz = 1200,
		TxPowerDbm = 37.0,
		DutyCycle = 0.6,
		Antenna = omni(0.0, 2.5),
		SensitivityDbm = -100,
		NoiseFigureDb = 6,
		RequiredSinrDb = 10,
		InterferenceRejectionDb = 0,
		Stability = 0.98,
		ContinuousEmission = false,
		Source = "Game value (generic MANET, not a real waveform)",
	},
	MANET_DATA_LBAND = {
		Id = "MANET_DATA_LBAND",
		DisplayName = "L-band wideband MANET data (generic)",
		SignalType = "Data",
		Modulation = "OFDM",
		DetectionClass = "Communications",
		Intentional = true,
		DefaultFrequencyMHz = 1350.0,
		MinFrequencyMHz = 1300.0,
		MaxFrequencyMHz = 2600.0,
		BandwidthKHz = 5000,
		TxPowerDbm = 35.0, -- ~3.2 W (public datasheet L/S-band figure)
		DutyCycle = 0.6,
		Antenna = omni(2.0, 2.5),
		SensitivityDbm = -95,
		NoiseFigureDb = 6,
		RequiredSinrDb = 10,
		InterferenceRejectionDb = 0,
		Stability = 0.98,
		ContinuousEmission = false,
		Source = "Public datasheet (power); game value (rest)",
	},
	UHF_SATCOM_UPLINK = {
		Id = "UHF_SATCOM_UPLINK",
		DisplayName = "UHF SATCOM uplink (generic)",
		SignalType = "Voice",
		Modulation = "PSK",
		DetectionClass = "Communications",
		Intentional = true,
		DefaultFrequencyMHz = 300.0,
		MinFrequencyMHz = 291.0,
		MaxFrequencyMHz = 318.3,
		BandwidthKHz = 25,
		TxPowerDbm = 40.0, -- 10 W (public datasheet SATCOM figure)
		DutyCycle = 1.0,
		Antenna = directional(8.0, 60, 15, 3.0, "Circular"),
		SensitivityDbm = -120,
		NoiseFigureDb = 4,
		RequiredSinrDb = 6,
		InterferenceRejectionDb = 0,
		Stability = 0.99,
		ContinuousEmission = false,
		Source = "Public datasheet (power, band); game value (rest)",
	},
	DRONE_C2_24 = {
		Id = "DRONE_C2_24",
		DisplayName = "2.4 GHz drone command link (generic FHSS)",
		SignalType = "Telemetry",
		Modulation = "FHSS",
		DetectionClass = "DroneLink",
		Intentional = true,
		DefaultFrequencyMHz = 2440.0,
		MinFrequencyMHz = 2400.0,
		MaxFrequencyMHz = 2483.5,
		BandwidthKHz = 2000,
		TxPowerDbm = 27.0,
		DutyCycle = 0.3,
		Antenna = omni(2.0, 1.0),
		SensitivityDbm = -100,
		NoiseFigureDb = 6,
		RequiredSinrDb = 6,
		InterferenceRejectionDb = 10, -- simulated hopping processing gain vs. narrow interference
		Stability = 0.95,
		ContinuousEmission = true,
		Source = "Game value",
	},
	DRONE_VIDEO_58 = {
		Id = "DRONE_VIDEO_58",
		DisplayName = "5.8 GHz drone video downlink (generic)",
		SignalType = "Data",
		Modulation = "OFDM",
		DetectionClass = "DroneLink",
		Intentional = true,
		DefaultFrequencyMHz = 5800.0,
		MinFrequencyMHz = 5650.0,
		MaxFrequencyMHz = 5925.0,
		BandwidthKHz = 20000,
		TxPowerDbm = 27.0,
		DutyCycle = 1.0,
		Antenna = omni(2.0, 1.0),
		SensitivityDbm = -88,
		NoiseFigureDb = 6,
		RequiredSinrDb = 12,
		InterferenceRejectionDb = 0,
		Stability = 0.95,
		ContinuousEmission = true,
		Source = "Game value",
	},
	SEARCH_RADAR_X = {
		Id = "SEARCH_RADAR_X",
		DisplayName = "X-band pulsed search radar (generic)",
		SignalType = "Radar",
		Modulation = "Pulse",
		DetectionClass = "RadarEmitter",
		Intentional = true,
		DefaultFrequencyMHz = 9400.0,
		MinFrequencyMHz = 8500.0,
		MaxFrequencyMHz = 10500.0,
		BandwidthKHz = 5000,
		TxPowerDbm = 50.0,
		DutyCycle = 0.001, -- average power of a pulsed emitter
		Antenna = directional(28.0, 3, 30, 4.0, "Horizontal"),
		SensitivityDbm = -100,
		NoiseFigureDb = 4,
		RequiredSinrDb = 13,
		InterferenceRejectionDb = 0,
		Stability = 0.99,
		ContinuousEmission = true,
		Source = "Game value (generic, not a real radar)",
	},
	BEACON_UHF = {
		Id = "BEACON_UHF",
		DisplayName = "UHF telemetry beacon (generic)",
		SignalType = "Beacon",
		Modulation = "FSK",
		DetectionClass = "ActiveTransmitter",
		Intentional = true,
		DefaultFrequencyMHz = 433.0,
		MinFrequencyMHz = 400.0,
		MaxFrequencyMHz = 470.0,
		BandwidthKHz = 12.5,
		TxPowerDbm = 20.0,
		DutyCycle = 0.2,
		Antenna = omni(0.0, 1.0),
		SensitivityDbm = -118,
		NoiseFigureDb = 6,
		RequiredSinrDb = 8,
		InterferenceRejectionDb = 0,
		Stability = 0.9,
		ContinuousEmission = true,
		Source = "Game value",
	},
	-- Jammer families (GAME VALUES, not real equipment settings). They work purely
	-- through the shared RF engine: their energy reaches receivers through the same
	-- terrain/structure propagation as any signal and counts as in-band
	-- interference in proportion to band overlap, so a wide barrage is diluted and
	-- a spot mode is concentrated on one channel. Phase 4 adds thermal limits,
	-- look-through and protected-frequency lists.
	JAMMER_BARRAGE_VHF = {
		Id = "JAMMER_BARRAGE_VHF",
		DisplayName = "Jammer - VHF barrage",
		SignalType = "Noise",
		Modulation = "Noise",
		DetectionClass = "ActiveTransmitter",
		Intentional = true,
		DefaultFrequencyMHz = 59.0,
		MinFrequencyMHz = 30.0,
		MaxFrequencyMHz = 88.0,
		BandwidthKHz = 58000,
		TxPowerDbm = 43.0,
		DutyCycle = 0.9,
		Antenna = omni(0.0, 3.0),
		SensitivityDbm = -200,
		NoiseFigureDb = 0,
		RequiredSinrDb = 0,
		InterferenceRejectionDb = 0,
		Stability = 0.85,
		ContinuousEmission = false,
		Source = "Game value",
	},
	JAMMER_BARRAGE_UHF = {
		Id = "JAMMER_BARRAGE_UHF",
		DisplayName = "Jammer - UHF barrage",
		SignalType = "Noise",
		Modulation = "Noise",
		DetectionClass = "ActiveTransmitter",
		Intentional = true,
		DefaultFrequencyMHz = 368.5,
		MinFrequencyMHz = 225.0,
		MaxFrequencyMHz = 512.0,
		BandwidthKHz = 287000,
		TxPowerDbm = 43.0,
		DutyCycle = 0.9,
		Antenna = omni(0.0, 3.0),
		SensitivityDbm = -200,
		NoiseFigureDb = 0,
		RequiredSinrDb = 0,
		InterferenceRejectionDb = 0,
		Stability = 0.85,
		ContinuousEmission = false,
		Source = "Game value",
	},
	JAMMER_SPOT = {
		Id = "JAMMER_SPOT",
		DisplayName = "Jammer - spot (tunable)",
		SignalType = "Noise",
		Modulation = "Noise",
		DetectionClass = "ActiveTransmitter",
		Intentional = true,
		DefaultFrequencyMHz = 45.0,
		MinFrequencyMHz = 30.0,
		MaxFrequencyMHz = 512.0,
		BandwidthKHz = 100,
		TxPowerDbm = 40.0,
		DutyCycle = 0.9,
		Antenna = omni(0.0, 3.0),
		SensitivityDbm = -200,
		NoiseFigureDb = 0,
		RequiredSinrDb = 0,
		InterferenceRejectionDb = 0,
		Stability = 0.85,
		ContinuousEmission = false,
		Source = "Game value",
		Notes = "Tune with the TransmissionChannel attribute (MHz or channel plan name).",
	},
	UNINTENTIONAL_EMISSION = {
		Id = "UNINTENTIONAL_EMISSION",
		DisplayName = "Unintentional electronic emission",
		SignalType = "Unintentional",
		Modulation = "Broadband",
		DetectionClass = "PassiveElectronic",
		Intentional = false,
		DefaultFrequencyMHz = 150.0,
		MinFrequencyMHz = 30.0,
		MaxFrequencyMHz = 1000.0,
		BandwidthKHz = 5000,
		TxPowerDbm = -45.0, -- very weak radiated signature from clocks/switching supplies (game value)
		DutyCycle = 1.0,
		Antenna = isotropic(0.0, 1.0),
		SensitivityDbm = -200, -- not a receiver
		NoiseFigureDb = 0,
		RequiredSinrDb = 0,
		InterferenceRejectionDb = 0,
		Stability = 0.7,
		ContinuousEmission = true,
		Source = "Game value",
		Notes = "Powered electronics that never transmit on purpose. Only short-range detection is plausible.",
	},
	BROADBAND_NOISE = {
		Id = "BROADBAND_NOISE",
		DisplayName = "Broadband electrical noise source",
		SignalType = "Noise",
		Modulation = "Noise",
		DetectionClass = "BackgroundSource",
		Intentional = false,
		DefaultFrequencyMHz = 60.0,
		MinFrequencyMHz = 30.0,
		MaxFrequencyMHz = 300.0,
		BandwidthKHz = 60000,
		TxPowerDbm = -10.0, -- generator / power line style noise (game value)
		DutyCycle = 1.0,
		Antenna = isotropic(0.0, 1.5),
		SensitivityDbm = -200,
		NoiseFigureDb = 0,
		RequiredSinrDb = 0,
		InterferenceRejectionDb = 0,
		Stability = 0.5,
		ContinuousEmission = true,
		Source = "Game value",
	},
}

local SignalProfiles = {}

SignalProfiles.DefaultProfileId = "UNINTENTIONAL_EMISSION"

function SignalProfiles.Get(id: string?): SignalProfile?
	if id == nil then
		return nil
	end
	return Profiles[id]
end

function SignalProfiles.GetOrDefault(id: string?): SignalProfile
	return (id and Profiles[id]) or Profiles[SignalProfiles.DefaultProfileId]
end

function SignalProfiles.All(): { [string]: SignalProfile }
	return Profiles
end

-- Register an additional profile at runtime (e.g. from a later phase module).
function SignalProfiles.Register(profile: SignalProfile)
	assert(type(profile.Id) == "string", "profile.Id required")
	Profiles[profile.Id] = profile
end

function SignalProfiles.CopyAntenna(spec: AntennaSpec): AntennaSpec
	return table.clone(spec)
end

return SignalProfiles
