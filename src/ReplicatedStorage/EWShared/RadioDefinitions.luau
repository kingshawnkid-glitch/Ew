--!strict
--[[
	RadioDefinitions
	Phase 2: static description of the AN/PRC-163 (game model). Shared by the
	server RadioService and the client radio screen.

	Band edges, power levels and the preset / key-slot counts come from the
	public L3Harris datasheet (docs/RESEARCH_NOTES.md section 1). Waveforms are
	game "families" mapped onto existing SignalProfiles; nothing real is
	reproduced. SATCOM needs a satellite model and is left for a later phase.

	CHANNELS
	  R/T 1  VULOS  30-88 (FM), 118-174 (AM), 225-512 (FM) MHz
	  R/T 2  UHF LOS 225-450 (FM) MHz, ANW2C 1300-2600 MHz (MANET data)

	FUNCTION KNOB
	  "OFF" | "LOAD" (key fill) | "Z" (zeroize) | "FP" (front-panel channel)
	  | 1..15 (knob presets: selects that preset on its R/T)
]]

export type Band = {
	Id: string,
	Label: string, -- waveform label shown on the screen
	MinMHz: number,
	MaxMHz: number,
	Profile: string, -- SignalProfiles id
	Mod: string, -- MOD field
	Traffic: string, -- TRF field ("VOC" | "DAT")
}

export type Preset = {
	Number: number,
	Name: string,
	Rt: number,
	RxMHz: number,
	TxMHz: number,
	Comsec: string, -- "PT" | "CT"
	KeySlot: number,
	Power: string, -- "LOW" | "MED" | "HIGH"
	Squelch: string, -- "NOI" | "TON" | "OFF"
}

local RadioDefinitions = {}

local PRC163 = {
	Id = "PRC163",
	DisplayName = "AN/PRC-163",
	Channels = {
		{
			Name = "R/T 1",
			Bands = {
				{ Id = "VLOW", Label = "VULOS", MinMHz = 30, MaxMHz = 88, Profile = "VHF_FM_VOICE", Mod = "FM", Traffic = "VOC" },
				{ Id = "VHIGH", Label = "VULOS", MinMHz = 118, MaxMHz = 174, Profile = "VHF_AM_VOICE", Mod = "AM", Traffic = "VOC" },
				{ Id = "UHF", Label = "VULOS", MinMHz = 225, MaxMHz = 512, Profile = "UHF_FM_VOICE", Mod = "FM", Traffic = "VOC" },
			} :: { Band },
		},
		{
			Name = "R/T 2",
			Bands = {
				{ Id = "UHF2", Label = "UHF LOS", MinMHz = 225, MaxMHz = 450, Profile = "UHF_FM_VOICE", Mod = "FM", Traffic = "VOC" },
				{ Id = "LS", Label = "ANW2C", MinMHz = 1300, MaxMHz = 2600, Profile = "MANET_DATA_LBAND", Mod = "OFDM", Traffic = "DAT" },
			} :: { Band },
		},
	},
	-- Conducted power per level (dBm): 0.25 W / 1 W / 5 W LOS, 3.2 W max on L/S-band.
	PowerLevelsDbm = { LOW = 24.0, MED = 30.0, HIGH = 37.0 },
	LBandPowerLevelsDbm = { LOW = 24.0, MED = 30.0, HIGH = 35.0 },
	PowerLevels = { "LOW", "MED", "HIGH" },
	SquelchModes = { "NOI", "TON", "OFF" },
	KeySlots = 6,
	PresetCount = 99,
	KnobPresets = 15,
	FrequencyStepMHz = 0.00001, -- 10 Hz tuning steps
	TxTimeoutSeconds = 30, -- stuck-PTT protection
	TextMaxLength = 120,
	VolumeMax = 8,
	DefaultKnob = 1 :: any,
	-- Default net plan (game values). Preset numbers 1..15 are reachable from the knob.
	Presets = {
		{ Number = 1, Name = "AMVOICE", Rt = 1, RxMHz = 142.5, TxMHz = 142.5, Comsec = "PT", KeySlot = 1, Power = "HIGH", Squelch = "NOI" },
		{ Number = 2, Name = "PLT-NET", Rt = 1, RxMHz = 45.0, TxMHz = 45.0, Comsec = "CT", KeySlot = 1, Power = "HIGH", Squelch = "NOI" },
		{ Number = 3, Name = "CO-NET", Rt = 1, RxMHz = 52.25, TxMHz = 52.25, Comsec = "CT", KeySlot = 1, Power = "HIGH", Squelch = "NOI" },
		{ Number = 4, Name = "BN-CMD", Rt = 1, RxMHz = 300.0, TxMHz = 300.0, Comsec = "CT", KeySlot = 2, Power = "HIGH", Squelch = "NOI" },
		{ Number = 5, Name = "FIRES", Rt = 1, RxMHz = 38.5, TxMHz = 38.5, Comsec = "CT", KeySlot = 1, Power = "HIGH", Squelch = "NOI" },
		{ Number = 6, Name = "MEDEVAC", Rt = 1, RxMHz = 52.9, TxMHz = 52.9, Comsec = "PT", KeySlot = 1, Power = "HIGH", Squelch = "NOI" },
		{ Number = 7, Name = "AIR-GND", Rt = 1, RxMHz = 251.0, TxMHz = 251.0, Comsec = "PT", KeySlot = 1, Power = "HIGH", Squelch = "NOI" },
		{ Number = 8, Name = "GUARD", Rt = 1, RxMHz = 243.0, TxMHz = 243.0, Comsec = "PT", KeySlot = 1, Power = "HIGH", Squelch = "NOI" },
		{ Number = 9, Name = "MANET-1", Rt = 2, RxMHz = 1350.0, TxMHz = 1350.0, Comsec = "CT", KeySlot = 3, Power = "HIGH", Squelch = "NOI" },
		{ Number = 10, Name = "UHF-LOS", Rt = 2, RxMHz = 310.0, TxMHz = 310.0, Comsec = "CT", KeySlot = 2, Power = "HIGH", Squelch = "NOI" },
		{ Number = 11, Name = "SQD-1", Rt = 1, RxMHz = 41.75, TxMHz = 41.75, Comsec = "CT", KeySlot = 1, Power = "MED", Squelch = "NOI" },
		{ Number = 12, Name = "SQD-2", Rt = 1, RxMHz = 42.25, TxMHz = 42.25, Comsec = "CT", KeySlot = 1, Power = "MED", Squelch = "NOI" },
		{ Number = 13, Name = "EOD-NET", Rt = 1, RxMHz = 47.5, TxMHz = 47.5, Comsec = "CT", KeySlot = 1, Power = "HIGH", Squelch = "NOI" },
		{ Number = 14, Name = "HARBOR", Rt = 1, RxMHz = 156.8, TxMHz = 156.8, Comsec = "PT", KeySlot = 1, Power = "HIGH", Squelch = "NOI" },
		{ Number = 15, Name = "MANET-2", Rt = 2, RxMHz = 1820.0, TxMHz = 1820.0, Comsec = "CT", KeySlot = 3, Power = "HIGH", Squelch = "NOI" },
	} :: { Preset },
}

RadioDefinitions.PRC163 = PRC163

function RadioDefinitions.GetPreset(number: number): Preset?
	for _, preset in ipairs(PRC163.Presets) do
		if preset.Number == number then
			return preset
		end
	end
	return nil
end

-- The band of a channel (R/T) containing a frequency, or nil when out of band.
function RadioDefinitions.BandFor(rt: number, mhz: number): Band?
	local channel = PRC163.Channels[rt]
	if not channel then
		return nil
	end
	for _, band in ipairs(channel.Bands) do
		if mhz >= band.MinMHz and mhz <= band.MaxMHz then
			return band
		end
	end
	return nil
end

-- Presets programmed for one R/T, in preset-number order.
function RadioDefinitions.PresetsFor(rt: number): { Preset }
	local out = {}
	for _, preset in ipairs(PRC163.Presets) do
		if preset.Rt == rt then
			table.insert(out, preset)
		end
	end
	return out
end

function RadioDefinitions.PresetLabel(preset: Preset?): string
	if not preset then
		return "FP"
	end
	return string.format("%02d-%s", preset.Number, preset.Name)
end

-- 10 Hz quantization, formatted the way the screen shows it (5 decimals).
function RadioDefinitions.QuantizeMHz(mhz: number): number
	local step = PRC163.FrequencyStepMHz
	return math.floor(mhz / step + 0.5) * step
end

function RadioDefinitions.FormatMHz(mhz: number): string
	return string.format("%.5f", mhz)
end

return RadioDefinitions
