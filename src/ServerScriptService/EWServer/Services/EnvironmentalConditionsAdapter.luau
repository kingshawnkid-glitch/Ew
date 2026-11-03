--[[
	EnvironmentalConditionsAdapter
	The only place the EW simulation reads weather / environmental state. Any
	weather system integrates by either:
	  * setting Attributes on Workspace (event-driven, no polling):
	        EW_RainRate        number  mm/h
	        EW_SnowRate        number  mm/h liquid-equivalent
	        EW_Fog             number  0..1  (0.5 = dense fog, ~0.5 g/m^3 liquid water)
	        EW_StormIntensity  number  0..1  (lightning / atmospheric noise)
	        EW_Wind            number  studs/s (cosmetic + antenna sway hook, no RF effect)
	        EW_NoiseEnvironment string "City" | "Residential" | "Rural" | "QuietRural"
	        EW_ExtraNoiseDb    number  added to external noise everywhere
	  * or calling Adapter:SetCondition(name, value) from server code.

	Local noise zones: BaseParts tagged "EWNoiseZone" (invisible volumes) with
	optional attributes NoiseEnvironment (string) and ExtraNoiseDb (number).
	A receiver inside the zone's box uses the zone values.

	PHYSICAL PLAUSIBILITY RULES (implemented below)
	  * Rain/snow/fog attenuation is computed with ITU-R P.838-style coefficients
	    and is negligible below ~2 GHz, so VHF/UHF tactical radios are not hurt
	    by ordinary rain; drone links at 5.8 GHz or Ku-band links are.
	  * Storms raise atmospheric noise mostly at low VHF (lightning noise falls
	    off steeply with frequency).
	  * Wind and visual weather intensity are exposed separately as COSMETIC
	    state so presentation layers never confuse them with propagation.
]]

local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("EWShared")
local RFMath = require(Shared.RFMath)
local SharedUtilities = require(Shared.SharedUtilities)

local Adapter = {}

Adapter.Changed = SharedUtilities.Signal.new("EnvironmentChanged")

local context
local config
local bag = SharedUtilities.ConnectionBag.new()

local conditions = {
	RainRate = 0,
	SnowRate = 0,
	Fog = 0,
	StormIntensity = 0,
	Wind = 0,
	NoiseEnvironment = "Rural",
	ExtraNoiseDb = 0,
}

local ATTRIBUTE_MAP = {
	EW_RainRate = "RainRate",
	EW_SnowRate = "SnowRate",
	EW_Fog = "Fog",
	EW_StormIntensity = "StormIntensity",
	EW_Wind = "Wind",
	EW_NoiseEnvironment = "NoiseEnvironment",
	EW_ExtraNoiseDb = "ExtraNoiseDb",
}

local zones: { BasePart } = {}

local function sanitize(name: string, value: any): any
	if name == "NoiseEnvironment" then
		if type(value) == "string" and config.Noise.Categories[value] then
			return value
		end
		return config.Noise.DefaultCategory
	end
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	if name == "Fog" or name == "StormIntensity" then
		return math.clamp(value, 0, 1)
	end
	if name == "ExtraNoiseDb" then
		return math.clamp(value, -20, 60)
	end
	return math.max(0, value)
end

function Adapter:Init(ctx)
	context = ctx
	config = ctx.Config
	conditions.NoiseEnvironment = config.Noise.DefaultCategory
end

function Adapter:Start()
	for attribute, name in pairs(ATTRIBUTE_MAP) do
		local value = workspace:GetAttribute(attribute)
		if value ~= nil then
			conditions[name] = sanitize(name, value)
		end
	end
	bag:Add(workspace.AttributeChanged:Connect(function(attribute)
		local name = ATTRIBUTE_MAP[attribute]
		if name then
			conditions[name] = sanitize(name, workspace:GetAttribute(attribute))
			Adapter.Changed:Fire(name, conditions[name])
		end
	end))
	local tag = config.Noise.NoiseZoneTag
	local function addZone(inst)
		if inst:IsA("BasePart") and not table.find(zones, inst) then
			table.insert(zones, inst)
		end
	end
	local function removeZone(inst)
		local i = table.find(zones, inst)
		if i then
			table.remove(zones, i)
		end
	end
	bag:Add(CollectionService:GetInstanceAddedSignal(tag):Connect(addZone))
	bag:Add(CollectionService:GetInstanceRemovedSignal(tag):Connect(removeZone))
	for _, inst in ipairs(CollectionService:GetTagged(tag)) do
		addZone(inst)
	end
end

function Adapter:SetCondition(name: string, value: any)
	if conditions[name] == nil then
		error("Unknown environmental condition: " .. tostring(name))
	end
	conditions[name] = sanitize(name, value)
	Adapter.Changed:Fire(name, conditions[name])
end

function Adapter:GetConditions()
	return table.clone(conditions)
end

-- Presentation-only state (rain sound, screen effects, antenna sway).
function Adapter:GetCosmeticState()
	return {
		RainIntensity = math.clamp(conditions.RainRate / 50, 0, 1),
		SnowIntensity = math.clamp(conditions.SnowRate / 10, 0, 1),
		Fog = conditions.Fog,
		Storm = conditions.StormIntensity,
		Wind = conditions.Wind,
	}
end

local function zoneAt(position: Vector3): BasePart?
	for _, zone in ipairs(zones) do
		if zone.Parent then
			local localPos = zone.CFrame:PointToObjectSpace(position)
			local half = zone.Size / 2
			if math.abs(localPos.X) <= half.X and math.abs(localPos.Y) <= half.Y and math.abs(localPos.Z) <= half.Z then
				return zone
			end
		end
	end
	return nil
end

-- External (environmental) noise figure Fa in dB above kTB at a receiver.
function Adapter:GetExternalNoiseFigureDb(position: Vector3, frequencyMHz: number): (number, string)
	local category = conditions.NoiseEnvironment
	local extra = conditions.ExtraNoiseDb
	local zone = zoneAt(position)
	if zone then
		local zc = zone:GetAttribute("NoiseEnvironment")
		if type(zc) == "string" and config.Noise.Categories[zc] then
			category = zc
		end
		local ze = zone:GetAttribute("ExtraNoiseDb")
		if type(ze) == "number" then
			extra += ze
		end
	end
	local curve = config.Noise.Categories[category] or config.Noise.Categories[config.Noise.DefaultCategory]
	local fa = RFMath.ManMadeNoiseFigureDb(curve.c, curve.d, frequencyMHz)
	local galactic = config.Noise.Categories.Galactic
	-- Galactic noise sets a floor for an outdoor antenna in the VHF range.
	local faGalactic = RFMath.ManMadeNoiseFigureDb(galactic.c, galactic.d, frequencyMHz)
	fa = RFMath.LinearToDb(RFMath.DbToLinear(fa) + RFMath.DbToLinear(faGalactic))
	if conditions.StormIntensity > 0 then
		-- Atmospheric noise boost: StormNoiseMaxDb at 30 MHz, falling 15 dB per decade.
		local boost = conditions.StormIntensity
			* math.max(0, config.Noise.StormNoiseMaxDb - 15 * math.log10(math.max(frequencyMHz, 1) / 30))
		fa += boost
	end
	return fa + extra, category
end

-- Weather path attenuation (dB) over a path length in meters.
function Adapter:GetPathWeatherLossDb(frequencyMHz: number, pathMeters: number): (number, { [string]: number })
	local fGHz = frequencyMHz / 1000
	local km = pathMeters / 1000
	local rain = RFMath.RainSpecificAttenuationDbPerKm(fGHz, conditions.RainRate) * km
	-- Wet snow is approximated as half the attenuation of equivalent liquid rain rate.
	local snow = RFMath.RainSpecificAttenuationDbPerKm(fGHz, conditions.SnowRate) * 0.5 * km
	local fog = RFMath.FogSpecificCoefficient(fGHz) * (conditions.Fog * 1.0) * km
	return rain + snow + fog, { Rain = rain, Snow = snow, Fog = fog }
end

return Adapter
