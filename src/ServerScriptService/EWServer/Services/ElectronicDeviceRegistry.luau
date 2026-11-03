--[[
	ElectronicDeviceRegistry
	Event-driven registry of every electronic object participating in the EW
	simulation. See docs/PHASE1_ARCHITECTURE.md section 3 for the full rules.

	REGISTRATION SOURCES
	  Flag : a BoolValue named "EWDetectable" inside a Model, Tool or BasePart
	         (Value true = eligible for detection, false = tracked but excluded
	          from detection results, removed BoolValue = unregistered)
	  Tag  : CollectionService tag "EWDevice" on the root (no BoolValue needed)
	  API  : Registry:RegisterDevice(root, options) used by equipment systems

	ROOT RESOLUTION (first match wins, starting at the BoolValue's parent)
	  1. nearest ancestor with attribute EWDeviceRoot = true
	  2. the parent Tool or nearest Tool ancestor (then: nearest worn Accessory)
	  3. the parent Model (never Workspace)
	  4. a BasePart: its parent Model if that Model is not a character, else the part
	  5. any other container: apply rules 3/4 to the nearest Model/BasePart ancestor

	WORLD CONTAINERS
	  Devices exist only while inside Workspace or a player's Backpack. A Tool in
	  a Backpack is positioned at its owner's character. Moving a device out of
	  the world (e.g. ServerStorage) unregisters it but keeps its power/battery
	  state (weak-keyed by instance, and by the EWSerial attribute for respawns).

	No polling: discovery uses DescendantAdded, Changed, AncestryChanged,
	AttributeChanged, Destroying and CollectionService signals. All changes are
	coalesced with task.defer so reparenting (Removing + Added) is one update.

	SIGNALS
	  DeviceRegistered(record)
	  DeviceUnregistered(record, reason)
	  DeviceChanged(record, changeKind)   changeKind = "Detectable" | "Configuration"
	                                       | "Owner" | "Emission" | "PowerAttribute" | "Pose"
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("EWShared")
local SharedUtilities = require(Shared.SharedUtilities)
local SignalProfiles = require(Shared.SignalProfiles)
local DeviceDefinitions = require(Shared.DeviceDefinitions)
local Types = require(Shared.EWTypes)

local SpatialIndex = require(script.Parent.SpatialIndex)

type DeviceRecord = Types.DeviceRecord
type Emitter = Types.Emitter
type Receiver = Types.Receiver

local Signal = SharedUtilities.Signal
local ConnectionBag = SharedUtilities.ConnectionBag

local Registry = {}

Registry.DeviceRegistered = Signal.new("DeviceRegistered")
Registry.DeviceUnregistered = Signal.new("DeviceUnregistered")
Registry.DeviceChanged = Signal.new("DeviceChanged")

-- Attributes read from the root (or, as a fallback, from the EWDetectable BoolValue).
Registry.SupportedAttributes = {
	"ElectronicType",
	"SignalProfile",
	"EmissionEnabled",
	"TransmissionChannel",
	"PowerState",
	"DetectionDifficulty",
	"SignalStrength",
	"ElectronicFaction",
	"CustomDisplayName",
	"EWAntennaHeight",
	"EWAntennaGain",
	"EWAntennaPattern",
	"EWBandwidthKHz",
	"EWNetworkId",
	"EWSecurityProfile",
	"EWSerial",
	"EWOwnerUserId",
	"EWPriority",
}

local context
local config
local FLAG_NAME = "EWDetectable"

local devices: { [string]: DeviceRecord } = {}
local deviceList: { DeviceRecord } = {}
local deviceIndex: { [DeviceRecord]: number } = {}
local byRoot: { [Instance]: DeviceRecord } = {}

type RootSources = {
	Flags: { [Instance]: boolean },
	Tag: boolean,
	API: { [string]: any }?,
	Bag: any, -- ConnectionBag for root-level watches (tag/API roots)
}
local rootSources: { [Instance]: RootSources } = {}
local flagRoot: { [Instance]: Instance } = {}
local flagBags: { [Instance]: any } = {}
local deviceBags: { [string]: any } = {}

local pendingFlags: { [Instance]: boolean } = {}
local pendingRoots: { [Instance]: boolean } = {}
local pendingReconfigure: { [DeviceRecord]: boolean } = {}
local pendingPose: { [DeviceRecord]: boolean } = {}
local processScheduled = false

local persisted = setmetatable({}, { __mode = "k" }) :: { [Instance]: any }
local serialCache: { [string]: { State: any, ExpiresAt: number } } = {}

local globalBag = ConnectionBag.new()
local playerBags: { [Player]: any } = {}
local backpackBags: { [Instance]: any } = {}

local spatial = SpatialIndex.new(256)
local nextDeviceNumber = 0
local positionCursor = 1

local counters = {
	Registrations = 0,
	Unregistrations = 0,
	FlagDiscoveries = 0,
	FlagChanges = 0,
	Reconfigurations = 0,
	RootMigrations = 0,
	OrphanFlags = 0,
	MultiFlagRoots = 0,
	PositionUpdates = 0,
	DeferredBatches = 0,
	RestoredStates = 0,
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function now(): number
	return os.clock()
end

local function isInWorld(inst: Instance): boolean
	if inst.Parent == nil then
		return false
	end
	if inst:IsDescendantOf(workspace) then
		return true
	end
	local backpack = inst:FindFirstAncestorOfClass("Backpack")
	return backpack ~= nil and backpack.Parent ~= nil and backpack.Parent:IsA("Player")
end

local function isCharacterLike(model: Instance): boolean
	return model:IsA("Model") and model:FindFirstChildOfClass("Humanoid") ~= nil
end

local function rootForPart(part: BasePart): Instance
	local model = part.Parent
	if model and model:IsA("Model") and model ~= workspace and not isCharacterLike(model) then
		return model
	end
	return part
end

local function resolveRoot(flag: Instance): Instance?
	local parent = flag.Parent
	if parent == nil or parent == workspace or parent == game then
		return nil
	end
	-- 1. Explicit override
	local node: Instance? = parent
	local depth = 0
	while node and node ~= workspace and node ~= game and depth < config.Registry.MaxRootSearchDepth do
		if node:IsA("Backpack") or node:IsA("Player") then
			break
		end
		if node:GetAttribute(config.Registry.RootOverrideAttribute) == true then
			return node
		end
		node = node.Parent
		depth += 1
	end
	-- 2. Tool
	if parent:IsA("Tool") then
		return parent
	end
	local tool = parent:FindFirstAncestorOfClass("Tool")
	if tool then
		return tool
	end
	-- 2b. Worn Accessory (e.g. an EW backpack on the character)
	if parent:IsA("Accessory") then
		return parent
	end
	local accessory = parent:FindFirstAncestorOfClass("Accessory")
	if accessory then
		return accessory
	end
	-- 3. Model
	if parent:IsA("Model") and parent ~= workspace then
		return parent
	end
	-- 4. BasePart
	if parent:IsA("BasePart") then
		return rootForPart(parent)
	end
	-- 5. Other containers: nearest Model / BasePart ancestor
	local ancestor = parent.Parent
	depth = 0
	while ancestor and ancestor ~= workspace and ancestor ~= game and depth < config.Registry.MaxRootSearchDepth do
		if ancestor:IsA("BasePart") then
			return rootForPart(ancestor)
		elseif ancestor:IsA("Model") then
			return ancestor
		elseif ancestor:IsA("Backpack") or ancestor:IsA("Player") then
			break
		end
		ancestor = ancestor.Parent
		depth += 1
	end
	return nil
end

local function resolveOwner(root: Instance): number?
	local backpack = root:FindFirstAncestorOfClass("Backpack")
	if backpack and backpack.Parent and backpack.Parent:IsA("Player") then
		return (backpack.Parent :: Player).UserId
	end
	local node = root
	local depth = 0
	while node and node ~= workspace and depth < 12 do
		if node:IsA("Model") then
			local player = Players:GetPlayerFromCharacter(node)
			if player then
				return player.UserId
			end
		end
		node = node.Parent
		depth += 1
	end
	local attr = root:GetAttribute("EWOwnerUserId")
	if type(attr) == "number" then
		return attr
	end
	return nil
end

local function resolveAnchor(root: Instance): BasePart?
	if root:IsA("BasePart") then
		return root
	end
	if root:IsA("Tool") then
		local handle = root:FindFirstChild("Handle")
		if handle and handle:IsA("BasePart") then
			return handle
		end
	end
	if root:IsA("Model") and root.PrimaryPart then
		return root.PrimaryPart
	end
	return root:FindFirstChildWhichIsA("BasePart", true)
end

local function resolveAntenna(root: Instance): Attachment?
	local found = root:FindFirstChild(config.Registry.AntennaAttachmentName, true)
	if found and found:IsA("Attachment") then
		return found
	end
	return nil
end

local function readAttributes(root: Instance, sources: RootSources?): { [string]: any }
	local attrs = {}
	local fallbacks = {}
	if sources then
		for flag in pairs(sources.Flags) do
			table.insert(fallbacks, flag)
		end
	end
	for _, name in ipairs(Registry.SupportedAttributes) do
		local value = root:GetAttribute(name)
		if value == nil then
			for _, flag in ipairs(fallbacks) do
				value = flag:GetAttribute(name)
				if value ~= nil then
					break
				end
			end
		end
		attrs[name] = value
	end
	if sources and sources.API then
		for k, v in pairs(sources.API) do
			if attrs[k] == nil then
				attrs[k] = v
			end
		end
	end
	return attrs
end

local function resolveFrequency(value: any, fallback: number): (number, string?)
	if type(value) == "number" and value > 0 then
		return value, nil
	end
	if type(value) == "string" then
		local planned = config.ChannelPlan[value]
		if planned then
			return planned, nil
		end
		local parsed = tonumber(value)
		if parsed and parsed > 0 then
			return parsed, nil
		end
		return fallback, "UNKNOWN_CHANNEL:" .. value
	end
	return fallback, nil
end

local function resolvePower(value: any, profile): number
	if type(value) == "number" then
		return value
	end
	if type(value) == "string" and profile.PowerLevelsDbm then
		local level = profile.PowerLevelsDbm[string.upper(value)]
		if level then
			return level
		end
	end
	return profile.TxPowerDbm
end

local function buildRadioConfiguration(record: DeviceRecord, attrs: { [string]: any }, keepTransmitting: boolean)
	local definition = DeviceDefinitions.Resolve(attrs.ElectronicType)
	local profileId = attrs.SignalProfile or definition.DefaultSignalProfile
	local profile = SignalProfiles.Get(profileId)
	local notes = {}
	if not profile then
		table.insert(notes, "UNKNOWN_SIGNAL_PROFILE:" .. tostring(profileId))
		profile = SignalProfiles.GetOrDefault(definition.DefaultSignalProfile)
	end
	local frequency, freqNote = resolveFrequency(attrs.TransmissionChannel, profile.DefaultFrequencyMHz)
	if freqNote then
		table.insert(notes, freqNote)
	end
	if frequency < profile.MinFrequencyMHz or frequency > profile.MaxFrequencyMHz then
		table.insert(notes, "FREQUENCY_OUTSIDE_PROFILE_RANGE")
	end

	local antenna = SignalProfiles.CopyAntenna(profile.Antenna)
	if type(attrs.EWAntennaGain) == "number" then
		antenna.GainDbi = attrs.EWAntennaGain
	end
	if type(attrs.EWAntennaHeight) == "number" then
		antenna.HeightOffsetStuds = attrs.EWAntennaHeight
	end
	if attrs.EWAntennaPattern == "Omni" or attrs.EWAntennaPattern == "Directional" or attrs.EWAntennaPattern == "Isotropic" then
		antenna.Pattern = attrs.EWAntennaPattern
	end

	local bandwidth = if type(attrs.EWBandwidthKHz) == "number" and attrs.EWBandwidthKHz > 0
		then attrs.EWBandwidthKHz
		else profile.BandwidthKHz
	local difficulty = if type(attrs.DetectionDifficulty) == "number"
		then math.clamp(attrs.DetectionDifficulty, 0, 1)
		else 0

	local previous = record.Emitters[1]
	local emissionEnabled: boolean
	if type(attrs.EmissionEnabled) == "boolean" then
		emissionEnabled = attrs.EmissionEnabled
	elseif keepTransmitting and previous then
		emissionEnabled = previous.Transmitting
	else
		emissionEnabled = definition.EmissionEnabledByDefault
	end

	local priority = if type(attrs.EWPriority) == "number" then math.clamp(math.floor(attrs.EWPriority), 1, 3) else definition.Priority

	local emitter: Emitter = {
		Id = record.Id .. ":TX1",
		DeviceId = record.Id,
		ProfileId = profile.Id,
		SignalType = profile.SignalType,
		Modulation = profile.Modulation,
		Intentional = profile.Intentional,
		FrequencyMHz = frequency,
		BandwidthKHz = bandwidth,
		TxPowerDbm = resolvePower(attrs.SignalStrength, profile),
		DutyCycle = profile.DutyCycle,
		Transmitting = emissionEnabled,
		ContinuousEmission = profile.ContinuousEmission,
		NetworkId = if type(attrs.EWNetworkId) == "string" then attrs.EWNetworkId else nil,
		SecurityProfile = if type(attrs.EWSecurityProfile) == "string" then attrs.EWSecurityProfile else nil,
		Priority = priority,
		Stability = profile.Stability,
		Antenna = antenna,
		SignatureReductionDb = 25 * difficulty,
	}
	record.Emitters = { emitter }

	local receivers = {}
	if definition.HasReceiver then
		local receiver: Receiver = {
			Id = record.Id .. ":RX1",
			DeviceId = record.Id,
			ProfileId = profile.Id,
			Modulation = profile.Modulation,
			FrequencyMHz = frequency,
			BandwidthKHz = bandwidth,
			SensitivityDbm = profile.SensitivityDbm,
			NoiseFigureDb = profile.NoiseFigureDb,
			RequiredSinrDb = profile.RequiredSinrDb,
			InterferenceRejectionDb = profile.InterferenceRejectionDb,
			NetworkId = emitter.NetworkId,
			SecurityProfile = emitter.SecurityProfile,
			Antenna = antenna,
			Enabled = true,
		}
		table.insert(receivers, receiver)
	end
	record.Receivers = receivers

	record.DefinitionId = definition.Id
	record.ElectronicType = definition.ElectronicType
	record.DetectionClass = profile.DetectionClass
	record.DetectionDifficulty = difficulty
	record.DisplayName = if type(attrs.CustomDisplayName) == "string" and attrs.CustomDisplayName ~= ""
		then attrs.CustomDisplayName
		else record.Root.Name
	record.Faction = if type(attrs.ElectronicFaction) == "string" then attrs.ElectronicFaction else nil
	record.Serial = if type(attrs.EWSerial) == "string" and attrs.EWSerial ~= "" then attrs.EWSerial else nil
	record.Attributes = attrs
	record.ConfigurationNotes = notes
	return definition
end

local function buildBattery(definition): Types.BatteryState?
	local spec = definition.Battery
	if not spec then
		return nil
	end
	return {
		CapacityWh = spec.CapacityWh,
		ChargeWh = spec.CapacityWh,
		IdleDrawW = spec.IdleDrawW,
		ReceiveDrawW = spec.ReceiveDrawW,
		TransmitDrawW = spec.TransmitDrawW,
		LowFraction = config.Power.LowBatteryFraction,
		CriticalFraction = config.Power.CriticalBatteryFraction,
		Removable = spec.Removable,
		LowWarned = false,
		CriticalWarned = false,
	}
end

local function initialPowerState(attrs, definition): Types.PowerState
	local attr = attrs.PowerState
	if attr == true or attr == "On" or attr == "on" or attr == "ON" then
		return "On"
	elseif attr == false or attr == "Off" or attr == "off" or attr == "OFF" then
		return "Off"
	end
	return definition.DefaultPowerState
end

local function captureState(record: DeviceRecord)
	return {
		PowerState = record.PowerState,
		Battery = record.Battery and table.clone(record.Battery) or nil,
		Transmitting = record.Emitters[1] and record.Emitters[1].Transmitting or false,
	}
end

local function computeDetectable(root: Instance, sources: RootSources): boolean
	local anyFlag = false
	local anyTrue = false
	for flag in pairs(sources.Flags) do
		anyFlag = true
		if flag:IsA("BoolValue") and (flag :: BoolValue).Value == true then
			anyTrue = true
		end
	end
	if anyFlag then
		return anyTrue
	end
	if sources.API and sources.API.Detectable == false then
		return false
	end
	if sources.Tag and root:GetAttribute(FLAG_NAME) == false then
		return false
	end
	return true
end

--------------------------------------------------------------------------------
-- Pose (position / antenna frame)
--------------------------------------------------------------------------------

local function computePose(record: DeviceRecord): (Vector3?, CFrame?)
	local root = record.Root
	local backpack = root:FindFirstAncestorOfClass("Backpack")
	if backpack then
		local player = backpack.Parent
		if player and player:IsA("Player") then
			local character = player.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart")
			if hrp and hrp:IsA("BasePart") then
				-- Carried on the vest/back: upright antenna slightly above the torso.
				local base = hrp.Position
				local look = hrp.CFrame.LookVector
				local flat = Vector3.new(look.X, 0, look.Z)
				if flat.Magnitude < 1e-3 then
					flat = Vector3.new(0, 0, -1)
				end
				local pos = base + Vector3.new(0, 1.0 + record.Emitters[1].Antenna.HeightOffsetStuds * 0.5, 0)
				return pos, CFrame.lookAt(pos, pos + flat.Unit)
			end
		end
		return nil, nil
	end
	if not root:IsDescendantOf(workspace) then
		return nil, nil
	end
	local antenna = record.AntennaAttachment
	if antenna and antenna.Parent and antenna:IsDescendantOf(root) then
		return antenna.WorldPosition, antenna.WorldCFrame
	end
	local anchor = record.AnchorPart
	if not (anchor and anchor.Parent and (anchor == root or anchor:IsDescendantOf(root))) then
		anchor = resolveAnchor(root)
		record.AnchorPart = anchor
	end
	local heightOffset = record.Emitters[1] and record.Emitters[1].Antenna.HeightOffsetStuds or 1
	local basePosition: Vector3? = nil
	local look = Vector3.new(0, 0, -1)
	if anchor then
		basePosition = anchor.Position
		look = anchor.CFrame.LookVector
	elseif root:IsA("Model") then
		local pivot = root:GetPivot()
		basePosition = pivot.Position
		look = pivot.LookVector
	end
	if not basePosition then
		return nil, nil
	end
	local pos = basePosition + Vector3.new(0, heightOffset, 0)
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, -1)
	end
	-- Without an explicit EWAntenna attachment the element is assumed upright,
	-- so arbitrary tool/handle orientations never create surprise polarization loss.
	return pos, CFrame.lookAt(pos, pos + flat.Unit)
end

function Registry:RefreshPose(record: DeviceRecord, timestamp: number?)
	local t = timestamp or now()
	local pos, cf = computePose(record)
	counters.PositionUpdates += 1
	if not pos then
		if record.InWorld then
			record.InWorld = false
			spatial:Remove(record.Id)
		end
		return false
	end
	local dt = t - record.LastPositionUpdate
	if dt > 0 and record.LastPositionUpdate > 0 and record.InWorld then
		local v = (pos - record.Position) / dt
		-- Smooth to avoid spikes from irregular sampling.
		record.Velocity = record.Velocity:Lerp(v, 0.5)
	end
	record.Position = pos
	record.AntennaCFrame = cf :: CFrame
	record.LastPositionUpdate = t
	record.InWorld = true
	spatial:Update(record.Id, pos)
	return true
end

--------------------------------------------------------------------------------
-- Register / unregister
--------------------------------------------------------------------------------

local function addToList(record: DeviceRecord)
	table.insert(deviceList, record)
	deviceIndex[record] = #deviceList
end

local function removeFromList(record: DeviceRecord)
	local index = deviceIndex[record]
	if not index then
		return
	end
	local last = deviceList[#deviceList]
	deviceList[index] = last
	deviceIndex[last] = index
	deviceList[#deviceList] = nil
	deviceIndex[record] = nil
end

local scheduleProcess -- forward declaration

local function connectDevice(record: DeviceRecord)
	local bag = ConnectionBag.new()
	local root = record.Root
	bag:Add(root.AttributeChanged:Connect(function(name)
		if name == "PowerState" then
			Registry.DeviceChanged:Fire(record, "PowerAttribute")
		end
		if table.find(Registry.SupportedAttributes, name) or name == FLAG_NAME then
			pendingReconfigure[record] = true
			scheduleProcess()
		end
	end))
	bag:Add(root.DescendantAdded:Connect(function(desc)
		if desc:IsA("Attachment") and desc.Name == config.Registry.AntennaAttachmentName then
			pendingPose[record] = true
			scheduleProcess()
		elseif desc:IsA("BasePart") and record.AnchorPart == nil then
			pendingPose[record] = true
			scheduleProcess()
		end
	end))
	bag:Add(root.DescendantRemoving:Connect(function(desc)
		if desc == record.AntennaAttachment or desc == record.AnchorPart then
			pendingPose[record] = true
			scheduleProcess()
		end
	end))
	bag:Add(root.Destroying:Connect(function()
		pendingRoots[root] = true
		scheduleProcess()
	end))
	deviceBags[record.Id] = bag
end

local function register(root: Instance, sources: RootSources, detectable: boolean): DeviceRecord
	nextDeviceNumber += 1
	local t = now()
	local record: DeviceRecord = {
		Id = SharedUtilities.ShortId("EW", nextDeviceNumber),
		Root = root,
		DefinitionId = "Generic",
		ElectronicType = "Generic",
		DetectionClass = "PassiveElectronic",
		DisplayName = root.Name,
		Faction = nil,
		Serial = nil,
		OwnerUserId = resolveOwner(root),
		Detectable = detectable,
		RegistrationSources = {},
		PowerState = "Off",
		PowerStateChangedAt = t,
		BootCompleteAt = nil,
		FaultReason = nil,
		Battery = nil,
		Emitters = {},
		Receivers = {},
		DetectionDifficulty = 0,
		Position = Vector3.zero,
		AntennaCFrame = CFrame.identity,
		Velocity = Vector3.zero,
		LastPositionUpdate = 0,
		NextPositionUpdate = 0,
		PositionInterval = config.Scheduler.DevicePositionMinInterval,
		InWorld = false,
		AnchorPart = resolveAnchor(root),
		AntennaAttachment = resolveAntenna(root),
		Revision = 1,
		RegisteredAt = t,
		Attributes = {},
	}
	record.RegistrationSources = {
		Flag = next(sources.Flags) ~= nil,
		Tag = sources.Tag,
		API = sources.API ~= nil,
	}
	local attrs = readAttributes(root, sources)
	local definition = buildRadioConfiguration(record, attrs, false)
	record.Battery = buildBattery(definition)
	record.PowerState = initialPowerState(attrs, definition)

	-- Restore persisted runtime state (unequip/re-insert or respawn with the same serial).
	local state = persisted[root]
	if record.Serial then
		local cached = serialCache[record.Serial]
		if not state and cached and cached.ExpiresAt > t then
			state = cached.State
		end
		-- Always consume: a serial's cached state must never resurrect on a later device.
		serialCache[record.Serial] = nil
	end
	if state then
		counters.RestoredStates += 1
		if attrs.PowerState == nil then
			record.PowerState = state.PowerState
		end
		if state.Battery and record.Battery then
			record.Battery.ChargeWh = math.clamp(state.Battery.ChargeWh, 0, record.Battery.CapacityWh)
			record.Battery.LowWarned = state.Battery.LowWarned
			record.Battery.CriticalWarned = state.Battery.CriticalWarned
		end
		if type(attrs.EmissionEnabled) ~= "boolean" and record.Emitters[1] then
			record.Emitters[1].Transmitting = state.Transmitting
		end
		persisted[root] = nil
	end
	if record.Battery and record.Battery.ChargeWh <= 0 and record.PowerState == "On" then
		record.PowerState = "Depleted"
	end

	devices[record.Id] = record
	byRoot[root] = record
	addToList(record)
	connectDevice(record)
	Registry:RefreshPose(record, t)
	counters.Registrations += 1
	Registry.DeviceRegistered:Fire(record)
	return record
end

local function unregister(record: DeviceRecord, reason: string)
	local root = record.Root
	local state = captureState(record)
	persisted[root] = state
	if record.Serial then
		serialCache[record.Serial] = { State = state, ExpiresAt = now() + config.Registry.PersistSecondsAfterRemoval }
	end
	local bag = deviceBags[record.Id]
	if bag then
		bag:Clean()
		deviceBags[record.Id] = nil
	end
	spatial:Remove(record.Id)
	devices[record.Id] = nil
	if byRoot[root] == record then
		byRoot[root] = nil
	end
	removeFromList(record)
	pendingReconfigure[record] = nil
	pendingPose[record] = nil
	record.InWorld = false
	counters.Unregistrations += 1
	Registry.DeviceUnregistered:Fire(record, reason)
end

--------------------------------------------------------------------------------
-- Source tracking
--------------------------------------------------------------------------------

local function getSources(root: Instance): RootSources
	local sources = rootSources[root]
	if not sources then
		local bag = ConnectionBag.new()
		sources = { Flags = {}, Tag = false, API = nil, Bag = bag }
		rootSources[root] = sources
		-- Root-level watches let tag/API devices re-register when they come back into the world.
		bag:Add(root.AncestryChanged:Connect(function()
			pendingRoots[root] = true
			scheduleProcess()
		end))
	end
	return sources
end

local function releaseSourcesIfEmpty(root: Instance)
	local sources = rootSources[root]
	if sources and next(sources.Flags) == nil and not sources.Tag and sources.API == nil then
		sources.Bag:Clean()
		rootSources[root] = nil
	end
end

local function evaluateRoot(root: Instance)
	local sources = rootSources[root]
	local record = byRoot[root]
	local hasSource = sources ~= nil and (next(sources.Flags) ~= nil or sources.Tag or sources.API ~= nil)
	local alive = root.Parent ~= nil and isInWorld(root)

	if hasSource and alive then
		local s = sources :: RootSources
		local flagCount = 0
		for _ in pairs(s.Flags) do
			flagCount += 1
		end
		if flagCount > 1 then
			counters.MultiFlagRoots += 1
		end
		local detectable = computeDetectable(root, s)
		if not record then
			register(root, s, detectable)
		else
			record.RegistrationSources = { Flag = flagCount > 0, Tag = s.Tag, API = s.API ~= nil }
			if record.Detectable ~= detectable then
				record.Detectable = detectable
				record.Revision += 1
				Registry.DeviceChanged:Fire(record, "Detectable")
			end
			local owner = resolveOwner(root)
			if owner ~= record.OwnerUserId then
				record.OwnerUserId = owner
				Registry.DeviceChanged:Fire(record, "Owner")
			end
			record.AnchorPart = resolveAnchor(root)
			record.AntennaAttachment = resolveAntenna(root)
			Registry:RefreshPose(record)
		end
	else
		if record then
			unregister(record, if root.Parent == nil then "Destroyed" elseif not hasSource then "SourceRemoved" else "LeftWorld")
		end
		if not hasSource then
			releaseSourcesIfEmpty(root)
		end
	end
end

local function untrackFlag(flag: Instance)
	local bag = flagBags[flag]
	if bag then
		bag:Clean()
		flagBags[flag] = nil
	end
	local root = flagRoot[flag]
	if root then
		flagRoot[flag] = nil
		local sources = rootSources[root]
		if sources then
			sources.Flags[flag] = nil
		end
		pendingRoots[root] = true
	end
end

local function processFlag(flag: Instance)
	if flag.Parent == nil or flag.Name ~= FLAG_NAME or not flag:IsA("BoolValue") or not isInWorld(flag) then
		untrackFlag(flag)
		return
	end
	local root = resolveRoot(flag)
	local oldRoot = flagRoot[flag]
	if root == nil then
		counters.OrphanFlags += 1
		if oldRoot then
			local sources = rootSources[oldRoot]
			if sources then
				sources.Flags[flag] = nil
			end
			flagRoot[flag] = nil
			pendingRoots[oldRoot] = true
		end
		return
	end
	if oldRoot ~= root then
		if oldRoot then
			counters.RootMigrations += 1
			local oldSources = rootSources[oldRoot]
			if oldSources then
				oldSources.Flags[flag] = nil
			end
			pendingRoots[oldRoot] = true
		end
		flagRoot[flag] = root
		getSources(root).Flags[flag] = true
	end
	pendingRoots[root] = true
end

local function trackFlag(flag: Instance)
	if flagBags[flag] then
		pendingFlags[flag] = true
		scheduleProcess()
		return
	end
	counters.FlagDiscoveries += 1
	local bag = ConnectionBag.new()
	flagBags[flag] = bag
	local function mark()
		pendingFlags[flag] = true
		scheduleProcess()
	end
	bag:Add((flag :: BoolValue).Changed:Connect(function()
		counters.FlagChanges += 1
		mark()
	end))
	bag:Add(flag.AncestryChanged:Connect(mark))
	bag:Add(flag.AttributeChanged:Connect(function()
		local root = flagRoot[flag]
		local record = root and byRoot[root]
		if record then
			pendingReconfigure[record] = true
		end
		mark()
	end))
	bag:Add(flag.Destroying:Connect(mark))
	mark()
end

local function processPending()
	processScheduled = false
	counters.DeferredBatches += 1
	local guard = 0
	while (next(pendingFlags) or next(pendingRoots) or next(pendingReconfigure) or next(pendingPose)) and guard < 8 do
		guard += 1
		local flags = pendingFlags
		pendingFlags = {}
		for flag in pairs(flags) do
			processFlag(flag)
		end
		local roots = pendingRoots
		pendingRoots = {}
		for root in pairs(roots) do
			evaluateRoot(root)
		end
		local reconfig = pendingReconfigure
		pendingReconfigure = {}
		for record in pairs(reconfig) do
			if devices[record.Id] == record then
				Registry:Reconfigure(record)
			end
		end
		local poses = pendingPose
		pendingPose = {}
		for record in pairs(poses) do
			if devices[record.Id] == record then
				record.AnchorPart = resolveAnchor(record.Root)
				record.AntennaAttachment = resolveAntenna(record.Root)
				Registry:RefreshPose(record)
				Registry.DeviceChanged:Fire(record, "Pose")
			end
		end
	end
end

scheduleProcess = function()
	if not processScheduled then
		processScheduled = true
		task.defer(processPending)
	end
end

local function onDescendantAdded(inst: Instance)
	if inst.ClassName ~= "BoolValue" then
		return
	end
	if inst.Name == FLAG_NAME then
		trackFlag(inst)
	elseif inst.Name == "Value" then
		-- Catch the common "parent first, rename after" pattern exactly once.
		task.defer(function()
			if inst.Name == FLAG_NAME and inst.Parent then
				trackFlag(inst)
			end
		end)
	end
end

local function hookBackpack(backpack: Instance)
	if backpackBags[backpack] then
		return
	end
	local bag = ConnectionBag.new()
	backpackBags[backpack] = bag
	bag:Add(backpack.DescendantAdded:Connect(onDescendantAdded))
	bag:Add(backpack.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			bag:Clean()
			backpackBags[backpack] = nil
		end
	end))
	for _, desc in ipairs(backpack:GetDescendants()) do
		onDescendantAdded(desc)
	end
end

local function hookPlayer(player: Player)
	if playerBags[player] then
		return
	end
	local bag = ConnectionBag.new()
	playerBags[player] = bag
	bag:Add(player.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then
			hookBackpack(child)
		end
	end))
	for _, child in ipairs(player:GetChildren()) do
		if child:IsA("Backpack") then
			hookBackpack(child)
		end
	end
end

local function onTagAdded(inst: Instance)
	local sources = getSources(inst)
	sources.Tag = true
	pendingRoots[inst] = true
	scheduleProcess()
end

local function onTagRemoved(inst: Instance)
	local sources = rootSources[inst]
	if sources then
		sources.Tag = false
	end
	pendingRoots[inst] = true
	scheduleProcess()
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function Registry:Init(ctx)
	context = ctx
	config = ctx.Config
	FLAG_NAME = config.Registry.FlagName
end

function Registry:Start()
	-- Initial discovery: one pass over existing content, then events only.
	globalBag:Add(workspace.DescendantAdded:Connect(onDescendantAdded))
	for _, desc in ipairs(workspace:GetDescendants()) do
		onDescendantAdded(desc)
	end
	globalBag:Add(Players.PlayerAdded:Connect(hookPlayer))
	globalBag:Add(Players.PlayerRemoving:Connect(function(player)
		local bag = playerBags[player]
		if bag then
			bag:Clean()
			playerBags[player] = nil
		end
	end))
	for _, player in ipairs(Players:GetPlayers()) do
		hookPlayer(player)
	end
	local tag = config.Registry.TagName
	globalBag:Add(CollectionService:GetInstanceAddedSignal(tag):Connect(onTagAdded))
	globalBag:Add(CollectionService:GetInstanceRemovedSignal(tag):Connect(onTagRemoved))
	for _, inst in ipairs(CollectionService:GetTagged(tag)) do
		onTagAdded(inst)
	end
	processPending()

	-- Adaptive pose refresh: moving / emitting devices often, idle ones rarely.
	context.Scheduler:AddJob("DevicePoses", 0, 2, function(_, budget)
		local deadline = os.clock() + budget * 0.35
		local count = #deviceList
		if count == 0 then
			return
		end
		local t = now()
		local minI = config.Scheduler.DevicePositionMinInterval
		local maxI = config.Scheduler.DevicePositionMaxInterval
		local processed = 0
		while processed < count and os.clock() < deadline do
			if positionCursor > #deviceList then
				positionCursor = 1
			end
			local record = deviceList[positionCursor]
			positionCursor += 1
			processed += 1
			if record and t >= record.NextPositionUpdate then
				local before = record.Position
				Registry:RefreshPose(record, t)
				local moved = (record.Position - before).Magnitude
				local emitting = record.Emitters[1] ~= nil and record.Emitters[1].Transmitting and record.PowerState == "On"
				if moved > 0.05 or emitting or record.Velocity.Magnitude > config.Scheduler.MovingSpeedThreshold then
					record.PositionInterval = minI
				else
					record.PositionInterval = math.min(record.PositionInterval * 1.5, maxI)
				end
				record.NextPositionUpdate = t + record.PositionInterval
			end
		end
	end)

	context.Scheduler:AddJob("RegistryMaintenance", 10, 8, function()
		local t = now()
		for serial, entry in pairs(serialCache) do
			if entry.ExpiresAt <= t then
				serialCache[serial] = nil
			end
		end
	end)
end

function Registry:Reconfigure(record: DeviceRecord)
	local sources = rootSources[record.Root]
	local attrs = readAttributes(record.Root, sources)
	local previous = record.Attributes or {}
	local oldDefinition = record.DefinitionId
	local definition = buildRadioConfiguration(record, attrs, true)
	if definition.Id ~= oldDefinition then
		-- Equipment type changed: rebuild the battery model but keep the charge fraction.
		local oldBattery = record.Battery
		record.Battery = buildBattery(definition)
		if oldBattery and record.Battery then
			record.Battery.ChargeWh = record.Battery.CapacityWh * (oldBattery.ChargeWh / math.max(oldBattery.CapacityWh, 1e-6))
		end
	end
	if sources then
		local detectable = computeDetectable(record.Root, sources)
		if detectable ~= record.Detectable then
			record.Detectable = detectable
			Registry.DeviceChanged:Fire(record, "Detectable")
		end
	end
	record.Revision += 1
	counters.Reconfigurations += 1
	if previous.EWOwnerUserId ~= attrs.EWOwnerUserId then
		record.OwnerUserId = resolveOwner(record.Root)
	end
	Registry.DeviceChanged:Fire(record, "Configuration")
end

-- Explicit registration for equipment systems (PRC-163, jammer, drones...).
-- options: any SupportedAttributes key plus { Detectable: boolean? }
function Registry:RegisterDevice(root: Instance, options: { [string]: any }?): DeviceRecord?
	local sources = getSources(root)
	sources.API = options or {}
	evaluateRoot(root)
	return byRoot[root]
end

function Registry:UnregisterDevice(root: Instance)
	local sources = rootSources[root]
	if sources then
		sources.API = nil
	end
	evaluateRoot(root)
end

-- Process queued registry changes immediately (tests, deterministic tooling).
function Registry:Flush()
	processPending()
end

function Registry:GetDevice(id: string): DeviceRecord?
	return devices[id]
end

function Registry:GetByRoot(root: Instance): DeviceRecord?
	return byRoot[root]
end

function Registry:FindDeviceFromInstance(inst: Instance?): DeviceRecord?
	local node = inst
	local depth = 0
	while node and depth < config.Registry.MaxRootSearchDepth do
		local record = byRoot[node]
		if record then
			return record
		end
		node = node.Parent
		depth += 1
	end
	return nil
end

function Registry:GetDeviceList(): { DeviceRecord }
	return deviceList
end

function Registry:Count(): number
	return #deviceList
end

function Registry:CountDetectable(): number
	local n = 0
	for _, record in ipairs(deviceList) do
		if record.Detectable then
			n += 1
		end
	end
	return n
end

-- Devices eligible for electronic DETECTION (EWDetectable true, in world).
function Registry:IsEligibleForDetection(record: DeviceRecord): boolean
	return record.Detectable and record.InWorld and devices[record.Id] == record
end

function Registry:QueryRadius(position: Vector3, radius: number): { DeviceRecord }
	local ids = spatial:QueryRadius(position, radius)
	local out = table.create(#ids)
	for _, id in ipairs(ids) do
		local record = devices[id]
		if record then
			table.insert(out, record)
		end
	end
	return out
end

function Registry:SetEmitterTransmitting(record: DeviceRecord, index: number, transmitting: boolean)
	local emitter = record.Emitters[index]
	if not emitter or emitter.Transmitting == transmitting then
		return
	end
	emitter.Transmitting = transmitting
	record.Revision += 1
	Registry.DeviceChanged:Fire(record, "Emission")
end

function Registry:GetCounters()
	local flagsTracked = 0
	for _ in pairs(flagBags) do
		flagsTracked += 1
	end
	local rootsTracked = 0
	for _ in pairs(rootSources) do
		rootsTracked += 1
	end
	local serials = 0
	for _ in pairs(serialCache) do
		serials += 1
	end
	local out = table.clone(counters)
	out.Devices = #deviceList
	out.Detectable = self:CountDetectable()
	out.FlagsTracked = flagsTracked
	out.RootsTracked = rootsTracked
	out.SerialCacheEntries = serials
	out.SpatialItems = spatial:Count()
	out.DeviceConnectionBags = 0
	for _ in pairs(deviceBags) do
		out.DeviceConnectionBags += 1
	end
	out.LiveConnections = SharedUtilities.GetLiveConnectionCount()
	return out
end

return Registry
