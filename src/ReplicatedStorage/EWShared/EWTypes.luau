--!strict
--[[
	EWTypes
	Shared type definitions for the Electronic Warfare (EW) simulation.

	UNIT CONVENTIONS (used everywhere in the EW code base)
	  * Power ................ dBm   (decibels relative to 1 mW)
	  * Gain ................. dBi   (antenna gain relative to an isotropic radiator)
	  * Loss ................. dB    (positive number = signal is weaker)
	  * Frequency ............ MHz
	  * Bandwidth ............ kHz
	  * World distance ....... studs (Roblox units)
	  * RF distance .......... meters (studs * EWConfig.Units.MetersPerStud)
	  * Energy ............... Wh    (battery capacity / charge)
	  * Electrical draw ...... W

	All numeric RF values in this project are GAME-SIMULATED values produced by
	documented simplified models (see docs/PHASE1_ARCHITECTURE.md). They are not
	measurements of real equipment performance.
]]

export type PowerState = "Off" | "Booting" | "On" | "Fault" | "Depleted"

-- Detection classes requested by the design brief (section 5).
export type DetectionClass =
	"ActiveTransmitter"
	| "PassiveElectronic"
	| "RadarEmitter"
	| "Communications"
	| "DroneLink"
	| "BackgroundSource"

export type SignalType = "Voice" | "Data" | "Telemetry" | "Beacon" | "Radar" | "Noise" | "Unintentional" | "Navigation"

export type Modulation = "FM" | "AM" | "PSK" | "FSK" | "OFDM" | "FHSS" | "DSSS" | "Pulse" | "Noise" | "CW" | "Broadband"

export type AntennaPattern = "Isotropic" | "Omni" | "Directional"

export type Polarization = "Vertical" | "Horizontal" | "Circular"

export type ObstructionClass = "Unobstructed" | "PartiallyObstructed" | "Obstructed" | "HeavilyObstructed"

export type QualityState = "Clear" | "Good" | "Degraded" | "Broken" | "Unusable" | "NoSignal" | "Incompatible" | "Offline"

export type AnalysisMode = "Full" | "ProfileOnly" | "Cached" | "Deferred"

export type AntennaSpec = {
	Pattern: AntennaPattern,
	GainDbi: number,
	BeamwidthDeg: number, -- only used by Directional patterns (half-power beamwidth)
	FrontToBackDb: number, -- maximum off-boresight attenuation for Directional patterns
	ElevationFloorDb: number, -- deepest null allowed for Omni (dipole-like) elevation pattern
	Polarization: Polarization,
	HeightOffsetStuds: number, -- used when no EWAntenna attachment exists
}

-- Static description of a waveform / emission type. Lives in SignalProfiles.
export type SignalProfile = {
	Id: string,
	DisplayName: string,
	SignalType: SignalType,
	Modulation: Modulation,
	DetectionClass: DetectionClass,
	Intentional: boolean, -- false for unintentional emissions (computers, generators)
	DefaultFrequencyMHz: number,
	MinFrequencyMHz: number,
	MaxFrequencyMHz: number,
	BandwidthKHz: number,
	TxPowerDbm: number, -- default transmit power (conducted, before antenna gain)
	PowerLevelsDbm: { [string]: number }?, -- optional named power levels (e.g. LOW/MED/HIGH)
	DutyCycle: number, -- 0..1 average fraction of time the emission is present while keyed
	Antenna: AntennaSpec,
	SensitivityDbm: number, -- receiver hard floor (below this nothing is demodulated)
	NoiseFigureDb: number, -- receiver noise figure
	RequiredSinrDb: number, -- SINR needed for minimally intelligible reception
	InterferenceRejectionDb: number, -- processing gain against uncorrelated interference (FHSS/DSSS)
	Stability: number, -- 0..1 (1 = perfectly stable oscillator/output)
	ContinuousEmission: boolean, -- true if the emitter radiates whenever powered (beacons, radars, noise)
	Source: string, -- provenance of the default numbers ("Public datasheet", "Game value", ...)
	Notes: string?,
}

export type Emitter = {
	Id: string,
	DeviceId: string,
	ProfileId: string,
	SignalType: SignalType,
	Modulation: Modulation,
	Intentional: boolean,
	FrequencyMHz: number,
	BandwidthKHz: number,
	TxPowerDbm: number,
	DutyCycle: number,
	Transmitting: boolean,
	ContinuousEmission: boolean,
	NetworkId: string?,
	SecurityProfile: string?,
	Priority: number,
	Stability: number,
	Antenna: AntennaSpec,
	SignatureReductionDb: number, -- derived from DetectionDifficulty (applies to ES detection only)
}

export type Receiver = {
	Id: string,
	DeviceId: string,
	ProfileId: string,
	Modulation: Modulation,
	FrequencyMHz: number,
	BandwidthKHz: number,
	SensitivityDbm: number,
	NoiseFigureDb: number,
	RequiredSinrDb: number,
	InterferenceRejectionDb: number,
	NetworkId: string?,
	SecurityProfile: string?,
	Antenna: AntennaSpec,
	Enabled: boolean,
}

export type BatteryState = {
	CapacityWh: number,
	ChargeWh: number,
	IdleDrawW: number,
	ReceiveDrawW: number,
	TransmitDrawW: number,
	LowFraction: number,
	CriticalFraction: number,
	Removable: boolean,
	LowWarned: boolean,
	CriticalWarned: boolean,
}

export type DeviceDefinition = {
	Id: string,
	DisplayName: string,
	ElectronicType: string,
	DetectionClass: DetectionClass,
	DefaultSignalProfile: string,
	HasReceiver: boolean,
	DefaultPowerState: PowerState,
	BootTimeSeconds: number,
	Battery: {
		CapacityWh: number,
		IdleDrawW: number,
		ReceiveDrawW: number,
		TransmitDrawW: number,
		Removable: boolean,
	}?, -- nil = externally/mains powered
	EmissionEnabledByDefault: boolean,
	Priority: number,
}

-- Server-side authoritative record for one registered electronic object.
export type DeviceRecord = {
	Id: string,
	Root: Instance,
	DefinitionId: string,
	ElectronicType: string,
	DetectionClass: DetectionClass,
	DisplayName: string,
	Faction: string?,
	Serial: string?,
	OwnerUserId: number?,
	Detectable: boolean, -- EWDetectable flag result (eligible for detection results)
	RegistrationSources: { [string]: boolean }, -- "Flag", "Tag", "API"
	PowerState: PowerState,
	PowerStateChangedAt: number,
	BootCompleteAt: number?,
	FaultReason: string?,
	Battery: BatteryState?,
	Emitters: { Emitter },
	Receivers: { Receiver },
	DetectionDifficulty: number,
	-- Cached spatial data (refreshed by the position job)
	Position: Vector3,
	AntennaCFrame: CFrame,
	Velocity: Vector3,
	LastPositionUpdate: number,
	NextPositionUpdate: number,
	PositionInterval: number,
	InWorld: boolean,
	-- Instance bindings
	AnchorPart: BasePart?,
	AntennaAttachment: Attachment?,
	Revision: number,
	RegisteredAt: number,
	Attributes: { [string]: any },
	ConfigurationNotes: { string }?,
}

export type ObstacleHit = {
	Instance: Instance?,
	MaterialKey: string,
	Kind: string, -- "Structure" | "Vegetation" | "Glass" | "Metal" | ...
	DistanceFromAStuds: number,
	ThicknessStuds: number,
	EntryPosition: Vector3,
	ExitPosition: Vector3,
	Capped: boolean,
	FixedLossDb: number?, -- EWAttenuationDb override
}

export type SubPath = {
	Obstacles: { ObstacleHit },
	VegetationStuds: number,
	Weight: number,
	OffsetStuds: number,
}

-- Frequency-independent geometry of a propagation path (cacheable).
export type PathGeometry = {
	A: Vector3,
	B: Vector3,
	DistanceStuds: number,
	HorizontalStuds: number,
	SampleCount: number,
	SampleSpacingStuds: number,
	SampleDistances: { number }, -- studs from A along the path
	SampleGround: { number }, -- surface height (terrain or static structure) used for diffraction
	SampleLos: { number }, -- straight line-of-sight height at each sample
	SampleKind: { number }, -- 0 = terrain/none, 1 = structure surface
	SampleExcluded: { boolean }, -- true = excluded from diffraction edge search (endpoint clutter / ground)
	GroundA: number,
	GroundB: number,
	MeanInteriorGround: number,
	TerrainSolidStuds: number,
	TerrainSolidMaterials: { [string]: number }, -- material name -> studs
	WaterPathStuds: number,
	CavityStuds: number, -- line of sight inside terrain-covered open space (tunnel/cave)
	EndpointWaterDepthA: number,
	EndpointWaterDepthB: number,
	SubPaths: { SubPath },
	EndpointClutterRadiusStuds: number,
	Mode: AnalysisMode,
	RaycastsUsed: number,
	VoxelReadsUsed: number,
	ComputedAt: number,
	Approximate: boolean,
	Notes: { string },
}

export type PropagationLosses = {
	FrequencyMHz: number,
	DiffractionDb: number,
	DiffractionEdges: number,
	PrincipalV: number,
	PrincipalEdgeDistanceStuds: number?,
	PrincipalEdgeHeightStuds: number?,
	TerrainPenetrationDb: number,
	StructureDb: number,
	StructureCenterDb: number,
	EndpointClutterDb: number,
	VegetationDb: number,
	WaterDb: number,
	CavityDb: number,
	OverTheTopDb: number,
	ThroughPathDb: number,
	ExcessDb: number,
	DominantPath: string, -- "Direct" | "OverTheTop" | "Through" | "Mixed"
	Class: ObstructionClass,
	LineOfSight: boolean,
	Explanation: { string },
}

export type CompatibilityResult = {
	FrequencyOffsetMHz: number,
	OverlapFraction: number, -- fraction of emitter power inside the receiver passband
	CouplingLossDb: number, -- loss applied to the emitter power to get in-band power
	InBand: boolean,
	ModulationMatch: boolean,
	NetworkMatch: boolean,
	SecurityMatch: boolean,
	Intelligible: boolean,
	Reasons: { string },
}

export type QualityResult = {
	State: QualityState,
	Score: number, -- 0..1
	MarginDb: number, -- SINR - required SINR
	SmoothedMarginDb: number,
	PacketLoss: number, -- 0..1 probability of a lost data unit / voice frame
	NoiseLevel: number, -- 0..1 audio hiss level for presentation layers
	DropoutRate: number, -- 0..1 probability of a voice dropout per presentation tick
	Readability: number, -- 1..5 (radio-check readability scale)
	Strength: number, -- 1..5 (radio-check signal strength scale)
}

export type LinkResult = {
	TxDeviceId: string,
	RxDeviceId: string,
	EmitterId: string,
	ReceiverId: string,
	FrequencyMHz: number,
	DistanceStuds: number,
	DistanceMeters: number,
	TxActive: boolean,
	EirpDbm: number,
	TxPowerDbm: number,
	TxGainDbi: number,
	RxGainDbi: number,
	PolarizationLossDb: number,
	FsplDb: number,
	PlaneEarthDb: number,
	BasicLossDb: number,
	BasicModel: string,
	EffectiveHeightTxM: number,
	EffectiveHeightRxM: number,
	Propagation: PropagationLosses?,
	WeatherLossDb: number,
	ShadowFadingDb: number,
	FastFadingDb: number,
	EquipmentJitterDb: number,
	TotalPathLossDb: number,
	ReceivedPowerDbm: number,
	InBandSignalDbm: number,
	NoiseFloorDbm: number,
	ExternalNoiseFigureDb: number,
	InterferenceDbm: number,
	InterfererCount: number,
	SnrDb: number,
	SinrDb: number,
	Compatibility: CompatibilityResult,
	Quality: QualityResult,
	AnalysisMode: AnalysisMode,
	Stale: boolean,
	Timestamp: number,
	Reasons: { string },
}

export type LinkWatchOptions = {
	Priority: number?, -- 1 (critical) .. 3 (background)
	EmitterIndex: number?,
	ReceiverIndex: number?,
	Label: string?,
	IncludeInterference: boolean?,
}

return {}
