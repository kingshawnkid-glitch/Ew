--!strict
--[[
	DeviceDefinitions
	Maps the optional "ElectronicType" attribute to sensible defaults so that an
	object with ONLY an EWDetectable BoolValue still works.

	Resolution order used by the registry:
	  1. ElectronicType attribute (exact Id or alias, case-insensitive)
	  2. "Generic" (powered passive electronics with an unintentional signature)

	Battery figures are game values chosen for session-length gameplay; they are
	scaled globally by EWConfig.Power.BatteryDrainMultiplier.
]]

local Types = require(script.Parent.EWTypes)

type DeviceDefinition = Types.DeviceDefinition

local Definitions: { [string]: DeviceDefinition } = {
	Generic = {
		Id = "Generic",
		DisplayName = "Electronic device",
		ElectronicType = "Generic",
		DetectionClass = "PassiveElectronic",
		DefaultSignalProfile = "UNINTENTIONAL_EMISSION",
		HasReceiver = false,
		DefaultPowerState = "On",
		BootTimeSeconds = 0,
		Battery = nil,
		EmissionEnabledByDefault = true,
		Priority = 3,
	},
	Communications = {
		Id = "Communications",
		DisplayName = "Radio",
		ElectronicType = "Communications",
		DetectionClass = "Communications",
		DefaultSignalProfile = "VHF_FM_VOICE",
		HasReceiver = true,
		DefaultPowerState = "On",
		BootTimeSeconds = 2,
		Battery = {
			CapacityWh = 60,
			IdleDrawW = 1.2,
			ReceiveDrawW = 0.8,
			TransmitDrawW = 14,
			Removable = true,
		},
		EmissionEnabledByDefault = false, -- radios only emit while keyed (PTT)
		Priority = 2,
	},
	ActiveTransmitter = {
		Id = "ActiveTransmitter",
		DisplayName = "Transmitter",
		ElectronicType = "ActiveTransmitter",
		DetectionClass = "ActiveTransmitter",
		DefaultSignalProfile = "BEACON_UHF",
		HasReceiver = false,
		DefaultPowerState = "On",
		BootTimeSeconds = 1,
		Battery = {
			CapacityWh = 40,
			IdleDrawW = 0.5,
			ReceiveDrawW = 0,
			TransmitDrawW = 2,
			Removable = true,
		},
		EmissionEnabledByDefault = true,
		Priority = 2,
		ManualEmission = true,
	},
	Radar = {
		Id = "Radar",
		DisplayName = "Radar",
		ElectronicType = "Radar",
		DetectionClass = "RadarEmitter",
		DefaultSignalProfile = "SEARCH_RADAR_X",
		HasReceiver = true,
		DefaultPowerState = "On",
		BootTimeSeconds = 5,
		Battery = nil,
		EmissionEnabledByDefault = true,
		Priority = 2,
	},
	DroneControl = {
		Id = "DroneControl",
		DisplayName = "Drone controller",
		ElectronicType = "DroneControl",
		DetectionClass = "DroneLink",
		DefaultSignalProfile = "DRONE_C2_24",
		HasReceiver = true,
		DefaultPowerState = "On",
		BootTimeSeconds = 2,
		Battery = {
			CapacityWh = 30,
			IdleDrawW = 2,
			ReceiveDrawW = 1,
			TransmitDrawW = 3,
			Removable = true,
		},
		EmissionEnabledByDefault = true,
		Priority = 2,
	},
	Jammer = {
		Id = "Jammer",
		DisplayName = "EW jammer backpack",
		ElectronicType = "Jammer",
		DetectionClass = "ActiveTransmitter",
		DefaultSignalProfile = "JAMMER_BARRAGE_VHF",
		HasReceiver = false,
		DefaultPowerState = "Off",
		BootTimeSeconds = 4,
		Battery = {
			CapacityWh = 150,
			IdleDrawW = 6,
			ReceiveDrawW = 0,
			TransmitDrawW = 110,
			Removable = true,
		},
		EmissionEnabledByDefault = false,
		Priority = 1,
		ManualEmission = true,
		Modes = {
			{ Id = "BARRAGE_VHF", Label = "BARRAGE VHF", Profile = "JAMMER_BARRAGE_VHF" },
			{ Id = "BARRAGE_UHF", Label = "BARRAGE UHF", Profile = "JAMMER_BARRAGE_UHF" },
			{ Id = "SPOT", Label = "SPOT", Profile = "JAMMER_SPOT" },
		},
	},
	BackgroundSource = {
		Id = "BackgroundSource",
		DisplayName = "Electrical noise source",
		ElectronicType = "BackgroundSource",
		DetectionClass = "BackgroundSource",
		DefaultSignalProfile = "BROADBAND_NOISE",
		HasReceiver = false,
		DefaultPowerState = "On",
		BootTimeSeconds = 0,
		Battery = nil,
		EmissionEnabledByDefault = true,
		Priority = 3,
	},
}

local Aliases: { [string]: string } = {
	generic = "Generic",
	passive = "Generic",
	passiveelectronic = "Generic",
	electronics = "Generic",
	communications = "Communications",
	comms = "Communications",
	radio = "Communications",
	transmitter = "ActiveTransmitter",
	activetransmitter = "ActiveTransmitter",
	beacon = "ActiveTransmitter",
	radar = "Radar",
	radaremitter = "Radar",
	drone = "DroneControl",
	dronecontrol = "DroneControl",
	dronelink = "DroneControl",
	telemetry = "DroneControl",
	background = "BackgroundSource",
	backgroundsource = "BackgroundSource",
	noise = "BackgroundSource",
	jammer = "Jammer",
	ewjammer = "Jammer",
	backpack = "Jammer",
	ewbackpack = "Jammer",
	jammerbackpack = "Jammer",
}

local DeviceDefinitions = {}

DeviceDefinitions.DefaultId = "Generic"

function DeviceDefinitions.Resolve(electronicType: any): DeviceDefinition
	if type(electronicType) == "string" then
		local direct = Definitions[electronicType]
		if direct then
			return direct
		end
		local alias = Aliases[string.lower((string.gsub(electronicType, "[%s_%-]", "")))]
		if alias then
			return Definitions[alias]
		end
	end
	return Definitions[DeviceDefinitions.DefaultId]
end

function DeviceDefinitions.Get(id: string): DeviceDefinition?
	return Definitions[id]
end

function DeviceDefinitions.Register(definition: DeviceDefinition)
	assert(type(definition.Id) == "string", "definition.Id required")
	Definitions[definition.Id] = definition
	Aliases[string.lower(definition.Id)] = definition.Id
end

function DeviceDefinitions.All(): { [string]: DeviceDefinition }
	return Definitions
end

return DeviceDefinitions
