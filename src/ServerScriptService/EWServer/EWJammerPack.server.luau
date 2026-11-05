--[[
	EWJammerPack (Script)
	Lets players wear the EW jammer backpack.

	Any Model in Workspace with the attribute EWWearStation = true becomes a
	pickup station. Its ProximityPrompt puts a copy of the model on the player's
	back as an Accessory, so the EW registry treats it as a carried device owned
	by that player (see PHASE1_GUIDE section 4, "Jammer backpack"). Triggering the
	prompt again takes the pack off. The station itself stays in place.

	Optional station attributes:
	  EWWearHandle    string   torso-sized part the gear is modelled around; it is placed on the torso (default: PrimaryPart / first part)
	  EWWearOffset    Vector3  extra offset from the torso, in torso space (studs)
	  EWWearRotation  Vector3  extra rotation in degrees (X, Y, Z)
	  CustomDisplayName, ElectronicType   copied onto the worn pack
]]

local Players = game:GetService("Players")

local PACK_NAME = "EW Jammer Pack"
local STATION_ATTRIBUTE = "EWWearStation"
local DEBOUNCE_SECONDS = 0.75

local lastUse: { [Player]: number } = {}

local function torsoOf(character: Model): BasePart?
	return (character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")) :: BasePart?
end

local function handleSourceOf(station: Model): BasePart?
	local named = station:GetAttribute("EWWearHandle")
	if type(named) == "string" then
		local part = station:FindFirstChild(named)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return station.PrimaryPart or station:FindFirstChildWhichIsA("BasePart")
end

local function buildPack(station: Model, player: Player): (Accessory?, BasePart?)
	local source = handleSourceOf(station)
	if not source then
		return nil, nil
	end
	local accessory = Instance.new("Accessory")
	accessory.Name = PACK_NAME
	local handle: BasePart? = nil
	for _, child in ipairs(station:GetChildren()) do
		if child:IsA("BasePart") then
			local copy = child:Clone()
			for _, d in ipairs(copy:GetDescendants()) do
				if d:IsA("ProximityPrompt") or d:IsA("JointInstance") or d:IsA("WeldConstraint") then
					d:Destroy()
				end
			end
			if child == source then
				copy.Name = "Handle"
				handle = copy
			end
			copy.Parent = accessory
		end
	end
	if not handle then
		accessory:Destroy()
		return nil, nil
	end
	for _, d in ipairs(accessory:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.Massless = true
			if d ~= handle then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = handle
				weld.Part1 = d
				weld.Parent = d
			end
		end
	end

	accessory:SetAttribute("ElectronicType", station:GetAttribute("ElectronicType") or "Jammer")
	accessory:SetAttribute("CustomDisplayName", station:GetAttribute("CustomDisplayName") or "EW BACKPACK")
	-- One serial per player so battery state survives taking the pack off and on.
	accessory:SetAttribute("EWSerial", "EWPACK-" .. player.UserId)
	local flag = Instance.new("BoolValue")
	flag.Name = "EWDetectable"
	flag.Value = true
	flag.Parent = handle
	-- EW menu point on the pack itself (behind the back), not inside the torso.
	if not accessory:FindFirstChild("EWInteract", true) then
		local point = Instance.new("Attachment")
		point.Name = "EWInteract"
		point:SetAttribute("EWAction", "Menu")
		point.CFrame = CFrame.new(0, 0.3, handle.Size.Z / 2 + 0.9)
		point.Parent = handle
	end
	return accessory, handle
end

local function wear(player: Player, station: Model)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local torso = character and torsoOf(character)
	if not (character and humanoid and torso) or humanoid.Health <= 0 then
		return
	end
	local accessory, handle = buildPack(station, player)
	if not (accessory and handle) then
		warn("[EW] JammerPack: station has no parts: " .. station:GetFullName())
		return
	end

	-- The handle part is the torso stand-in the gear was modelled around (the
	-- harness wraps it, the pack sits behind it), so it lines up with the torso.
	local offset = station:GetAttribute("EWWearOffset")
	local rotation = station:GetAttribute("EWWearRotation")
	local extra = if typeof(offset) == "Vector3" then offset else Vector3.zero
	local angles = if typeof(rotation) == "Vector3" then rotation else Vector3.zero
	local packOnTorso = CFrame.new(extra)
		* CFrame.Angles(math.rad(angles.X), math.rad(angles.Y), math.rad(angles.Z))

	-- Mount through the rig's back attachment so the Humanoid builds the weld.
	-- (An Accessory without a matching attachment falls back to the legacy hat
	-- behaviour and gets welded to the head.)
	local back = torso:FindFirstChild("BodyBackAttachment")
	local backOnTorso = if back and back:IsA("Attachment") then back.CFrame else CFrame.new(0, 0, torso.Size.Z / 2)
	if not back then
		back = Instance.new("Attachment")
		back.Name = "BodyBackAttachment"
		back.CFrame = backOnTorso
		back.Parent = torso
	end
	local mount = Instance.new("Attachment")
	mount.Name = "BodyBackAttachment"
	mount.CFrame = packOnTorso:Inverse() * backOnTorso
	mount.Parent = handle
	-- Move every part together: the WeldConstraints lock in the offsets the parts
	-- have when the pack enters the world.
	local move = (torso.CFrame * packOnTorso) * handle.CFrame:Inverse()
	for _, d in ipairs(accessory:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CFrame = move * d.CFrame
		end
	end
	humanoid:AddAccessory(accessory)
end

local function onTriggered(station: Model, player: Player)
	local now = os.clock()
	if (lastUse[player] or 0) + DEBOUNCE_SECONDS > now then
		return
	end
	lastUse[player] = now
	local character = player.Character
	if not character then
		return
	end
	local worn = character:FindFirstChild(PACK_NAME)
	if worn then
		worn:Destroy()
	else
		wear(player, station)
	end
end

local function setupStation(station: Instance)
	if not station:IsA("Model") or station:GetAttribute(STATION_ATTRIBUTE) ~= true then
		return
	end
	if station:FindFirstChild("EWWearPrompt", true) then
		return
	end
	local source = handleSourceOf(station)
	if not source then
		return
	end
	local point = Instance.new("Attachment")
	point.Name = "EWWearPoint"
	point.Parent = source
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "EWWearPrompt"
	prompt.ActionText = "Wear / Remove"
	prompt.ObjectText = station:GetAttribute("CustomDisplayName") or "EW Jammer Pack"
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = point
	prompt.Triggered:Connect(function(player)
		onTriggered(station, player)
	end)
end

for _, inst in ipairs(workspace:GetDescendants()) do
	setupStation(inst)
end
workspace.DescendantAdded:Connect(function(inst)
	if inst:IsA("Model") then
		task.defer(setupStation, inst)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	lastUse[player] = nil
end)
