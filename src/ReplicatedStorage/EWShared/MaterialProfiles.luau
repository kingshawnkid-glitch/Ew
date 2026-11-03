--!strict
--[[
	MaterialProfiles
	Configurable RF attenuation for structure materials (BaseParts) and terrain
	voxel materials.

	Structure obstacle loss (per penetrated obstacle):
	    L = (EntryLossDb + LossDbPerMeter * thickness_m) * (f_MHz / 1000) ^ FrequencyExponent
	    capped at OpaqueLossDb.
	The 1 GHz reference values are game values loosely informed by published
	building-material measurements (concrete and brick attenuate far more than
	wood or plain glass; metal enclosures are leakage-limited; loss rises with
	frequency). They are not measurements.

	Terrain voxel loss (per meter of solid terrain along the line of sight):
	    L/m = LossDbPerMeterAt100MHz * (f_MHz / 100) ^ FrequencyExponent

	Map builders can override any part with attributes:
	    EWMaterial     = "Concrete" | "Wood" | ... (any key below)
	    EWAttenuationDb = number  (fixed loss for this part, ignores thickness)
	    EWIgnore       = true     (part is never an RF obstacle)
]]

export type StructureMaterial = {
	Key: string,
	Kind: string, -- "Structure" | "Glass" | "Metal" | "Vegetation" | "Water" | "Ignore"
	EntryLossDb: number,
	LossDbPerMeter: number,
	FrequencyExponent: number,
}

export type TerrainMaterial = {
	Key: string,
	LossDbPerMeterAt100MHz: number,
	FrequencyExponent: number,
}

local MaterialProfiles = {}

MaterialProfiles.OpaqueLossDb = 100

local Structure: { [string]: StructureMaterial } = {}
local function S(key: string, kind: string, entry: number, perMeter: number, exponent: number)
	Structure[key] = {
		Key = key,
		Kind = kind,
		EntryLossDb = entry,
		LossDbPerMeter = perMeter,
		FrequencyExponent = exponent,
	}
end

-- key                kind          entry  dB/m  freqExp
S("Default", "Structure", 3.0, 15, 0.40)
S("Plastic", "Structure", 2.5, 12, 0.40)
S("SmoothPlastic", "Structure", 2.5, 12, 0.40)
S("Neon", "Structure", 2.5, 12, 0.40)
S("Concrete", "Structure", 5.0, 40, 0.50)
S("Pavement", "Structure", 5.0, 40, 0.50)
S("Asphalt", "Structure", 4.0, 35, 0.50)
S("Brick", "Structure", 3.0, 25, 0.45)
S("Cobblestone", "Structure", 3.5, 30, 0.45)
S("Marble", "Structure", 4.0, 30, 0.45)
S("Granite", "Structure", 4.0, 30, 0.45)
S("Slate", "Structure", 4.0, 30, 0.45)
S("Basalt", "Structure", 4.0, 30, 0.45)
S("Rock", "Structure", 4.0, 30, 0.45)
S("Limestone", "Structure", 3.5, 28, 0.45)
S("Sandstone", "Structure", 3.5, 28, 0.45)
S("Pebble", "Structure", 3.0, 25, 0.45)
S("CrackedLava", "Structure", 4.0, 30, 0.45)
S("CeramicTiles", "Structure", 3.0, 25, 0.45)
S("ClayRoofTiles", "Structure", 2.5, 20, 0.45)
S("RoofShingles", "Structure", 2.0, 15, 0.40)
S("Plaster", "Structure", 2.0, 15, 0.40)
S("Wood", "Structure", 1.5, 10, 0.35)
S("WoodPlanks", "Structure", 1.5, 10, 0.35)
S("Cardboard", "Structure", 0.5, 3, 0.30)
S("Fabric", "Structure", 0.5, 2, 0.30)
S("Leather", "Structure", 0.5, 3, 0.30)
S("Carpet", "Structure", 0.5, 3, 0.30)
S("Rubber", "Structure", 1.0, 8, 0.30)
S("Sand", "Structure", 1.5, 15, 0.40) -- sandbags / berms made of parts
S("Ground", "Structure", 2.0, 20, 0.40)
S("Mud", "Structure", 2.5, 25, 0.40)
S("Salt", "Structure", 2.0, 20, 0.40)
S("Snow", "Structure", 0.5, 2, 0.30)
S("Ice", "Structure", 0.8, 3, 0.30)
S("Glacier", "Structure", 0.8, 3, 0.30)
S("Glass", "Glass", 2.0, 20, 0.20)
S("Metal", "Metal", 28.0, 10, 0.10)
S("DiamondPlate", "Metal", 28.0, 10, 0.10)
S("CorrodedMetal", "Metal", 24.0, 10, 0.10)
S("Foil", "Metal", 22.0, 0, 0.10)
S("Grass", "Vegetation", 0, 0, 0)
S("LeafyGrass", "Vegetation", 0, 0, 0)
S("ForceField", "Ignore", 0, 0, 0)
S("Air", "Ignore", 0, 0, 0)
S("Water", "Water", 0, 0, 0)

local Terrain: { [string]: TerrainMaterial } = {}
local function T(key: string, perMeter: number, exponent: number)
	Terrain[key] = { Key = key, LossDbPerMeterAt100MHz = perMeter, FrequencyExponent = exponent }
end

-- Moist soils absorb strongly; dry rock, sand and ice are far more transparent.
T("Default", 3.0, 0.35)
T("Ground", 4.0, 0.35)
T("Mud", 5.0, 0.35)
T("Grass", 4.0, 0.35)
T("LeafyGrass", 4.0, 0.35)
T("Sand", 1.5, 0.35)
T("Salt", 3.0, 0.35)
T("Rock", 2.0, 0.35)
T("Basalt", 2.0, 0.35)
T("Slate", 2.0, 0.35)
T("Granite", 2.0, 0.35)
T("Limestone", 2.2, 0.35)
T("Sandstone", 2.0, 0.35)
T("Marble", 2.0, 0.35)
T("CrackedLava", 2.0, 0.35)
T("Pebble", 2.5, 0.35)
T("Cobblestone", 2.5, 0.35)
T("Concrete", 3.0, 0.40)
T("Pavement", 3.0, 0.40)
T("Asphalt", 3.0, 0.40)
T("Brick", 3.0, 0.40)
T("WoodPlanks", 1.0, 0.30)
T("Snow", 0.3, 0.30)
T("Glacier", 0.15, 0.30)
T("Ice", 0.15, 0.30)

function MaterialProfiles.GetStructure(materialName: string?): StructureMaterial
	if materialName then
		local profile = Structure[materialName]
		if profile then
			return profile
		end
	end
	return Structure.Default
end

function MaterialProfiles.GetTerrain(materialName: string?): TerrainMaterial
	if materialName then
		local profile = Terrain[materialName]
		if profile then
			return profile
		end
	end
	return Terrain.Default
end

function MaterialProfiles.StructureLossDb(profile: StructureMaterial, thicknessMeters: number, frequencyMHz: number): number
	if profile.Kind == "Ignore" or profile.Kind == "Vegetation" or profile.Kind == "Water" then
		return 0
	end
	local base = profile.EntryLossDb + profile.LossDbPerMeter * math.max(thicknessMeters, 0)
	local factor = (math.max(frequencyMHz, 1) / 1000) ^ profile.FrequencyExponent
	return math.min(base * factor, MaterialProfiles.OpaqueLossDb)
end

function MaterialProfiles.TerrainLossDbPerMeter(profile: TerrainMaterial, frequencyMHz: number): number
	return profile.LossDbPerMeterAt100MHz * (math.max(frequencyMHz, 1) / 100) ^ profile.FrequencyExponent
end

-- Allow designers to add or tune materials at runtime.
function MaterialProfiles.SetStructure(key: string, kind: string, entry: number, perMeter: number, exponent: number)
	S(key, kind, entry, perMeter, exponent)
end

function MaterialProfiles.SetTerrain(key: string, perMeter: number, exponent: number)
	T(key, perMeter, exponent)
end

return MaterialProfiles
