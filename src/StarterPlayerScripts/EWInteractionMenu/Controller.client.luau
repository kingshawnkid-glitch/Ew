--[[
	EW Interaction Menu - Controller (LocalScript)
	Rebuilt from the provided "INTERACTION MENU" for EW equipment only. The Combat
	Breaching module, its ReplicatedStorage dependency and the INTERACT_MENU tag
	requirement are gone: any object holding an EWDetectable BoolValue (e.g. the
	EW jammer backpack) is picked up automatically.

	USE
	  Hold Left Alt (keyboard) or R3 (gamepad) near EW gear, or tap the EW button
	  on touch devices. A white dot + label appears on the gear (same look as the
	  original menu). Click it to open the device menu: Power, Emission, Mode >,
	  Battery >, Status. Labels and dot colours show the server's live state.

	INTERACTION POINTS (optional, for gear like the screenshot)
	  Add Attachments named "EWInteract" anywhere inside the device, with:
	    EWAction (string) = "Menu" | "Power" | "Emission" | "Battery" | "Mode" | "Status"
	    Text     (string) = optional label override, e.g. "JAMMER CONTROL"
	  Without any EWInteract attachment the device gets one "Menu" point at its
	  main part (the part holding the BoolValue, or Handle / PrimaryPart).

	ROOT RULES (mirror the server registry): EWDeviceRoot attribute ancestor,
	Tool, worn Accessory, Model, or the BasePart itself.

	The client only REQUESTS. The server validates ownership (carrier or nearby
	teammate), range, rate limits and replies with authoritative state.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Templates = require(script.Parent:WaitForChild("Templates"))
local interactsFolder = script.Parent:WaitForChild("Interacts")

local CONFIG = {
	HoldKeys = { Enum.KeyCode.LeftAlt, Enum.KeyCode.ButtonR3 },
	FlagName = "EWDetectable",
	PointAttachmentName = "EWInteract",
	RootOverrideAttribute = "EWDeviceRoot",
	DefaultModule = "EW",
	SelectorDegreesPerSecond = 110,
	VisibilityCheckSeconds = 0.1,
}

--------------------------------------------------------------------------------
-- Modules (Interacts folder): EW by default; a device may name another with
-- the attribute EWMenuModule on its root.
--------------------------------------------------------------------------------
local modules = {}
for _, module in ipairs(interactsFolder:GetChildren()) do
	if module:IsA("ModuleScript") then
		modules[module.Name] = require(module)
	end
end

--------------------------------------------------------------------------------
-- Local UI root (click sound, touch toggle)
--------------------------------------------------------------------------------
local screen = Instance.new("ScreenGui")
screen.Name = "EWInteractionMenu"
screen.ResetOnSpawn = false
screen.Parent = playerGui

local clickSound = Instance.new("Sound")
clickSound.Name = "Clicked"
clickSound.SoundId = Templates.ClickSoundId
clickSound.Volume = 0.1
clickSound.Parent = screen

local character = player.Character or player.CharacterAdded:Wait()
local characterRoot: BasePart? = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?

local holding = false
local touchToggled = false
local activeSelector: ImageLabel? = nil

--------------------------------------------------------------------------------
-- Device tracking
--------------------------------------------------------------------------------
type Point = {
	Attachment: Attachment,
	Action: string,
	Label: string?,
	Generated: boolean,
	Gui: BillboardGui?,
	Opened: string?, -- id of the entry whose third column is open
}

type Device = {
	Flag: BoolValue,
	Root: Instance,
	Anchor: BasePart?,
	DisplayName: string,
	Module: any,
	Points: { Point },
	PointsDirty: boolean,
	Connections: { RBXScriptConnection },
	InRange: boolean,
}

local devices: { [Instance]: Device } = {}

local function isCharacterModel(inst: Instance): boolean
	return inst:IsA("Model") and inst:FindFirstChildOfClass("Humanoid") ~= nil
end

local function rootForPart(part: BasePart): Instance
	local model = part.Parent
	if model and model:IsA("Model") and model ~= workspace and not isCharacterModel(model) then
		return model
	end
	return part
end

local function resolveRoot(flag: Instance): Instance?
	local parent = flag.Parent
	if parent == nil or parent == workspace then
		return nil
	end
	local node: Instance? = parent
	while node and node ~= workspace and node ~= game do
		if node:GetAttribute(CONFIG.RootOverrideAttribute) == true then
			return node
		end
		node = node.Parent
	end
	if parent:IsA("Tool") then
		return parent
	end
	local tool = parent:FindFirstAncestorOfClass("Tool")
	if tool then
		return tool
	end
	if parent:IsA("Accessory") then
		return parent
	end
	local accessory = parent:FindFirstAncestorOfClass("Accessory")
	if accessory then
		return accessory
	end
	if parent:IsA("Model") and parent ~= workspace and not isCharacterModel(parent) then
		return parent
	end
	if parent:IsA("BasePart") then
		return rootForPart(parent)
	end
	local part = parent:FindFirstAncestorWhichIsA("BasePart")
	if part then
		return rootForPart(part)
	end
	return nil
end

local function findAnchor(flag: Instance, root: Instance): BasePart?
	if flag.Parent and flag.Parent:IsA("BasePart") then
		return flag.Parent :: BasePart
	end
	if root:IsA("BasePart") then
		return root
	end
	local handle = root:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		return handle
	end
	if root:IsA("Model") and root.PrimaryPart then
		return root.PrimaryPart
	end
	return root:FindFirstChildWhichIsA("BasePart", true)
end

local function destroyPointGui(point: Point)
	if point.Gui then
		point.Gui:Destroy()
		point.Gui = nil
	end
	point.Opened = nil
end

local function clearPoints(device: Device)
	for _, point in ipairs(device.Points) do
		destroyPointGui(point)
		if point.Generated and point.Attachment then
			point.Attachment:Destroy()
		end
	end
	table.clear(device.Points)
end

local function buildPoints(device: Device)
	clearPoints(device)
	for _, desc in ipairs(device.Root:GetDescendants()) do
		if desc:IsA("Attachment") and (desc.Name == CONFIG.PointAttachmentName or desc:GetAttribute("EWAction") ~= nil) then
			local action = desc:GetAttribute("EWAction")
			local label = desc:GetAttribute("Text")
			table.insert(device.Points, {
				Attachment = desc,
				Action = if type(action) == "string" then action else "Menu",
				Label = if type(label) == "string" then label else nil,
				Generated = false,
				Gui = nil,
				Opened = nil,
			})
		end
	end
	if #device.Points == 0 and device.Anchor then
		local attachment = Instance.new("Attachment")
		attachment.Name = "EWMenuPoint"
		attachment.Parent = device.Anchor -- local only; never replicates
		table.insert(device.Points, {
			Attachment = attachment,
			Action = "Menu",
			Label = nil,
			Generated = true,
			Gui = nil,
			Opened = nil,
		})
	end
	device.PointsDirty = false
end

local function untrack(flag: Instance)
	local device = devices[flag]
	if not device then
		return
	end
	devices[flag] = nil
	clearPoints(device)
	for _, connection in ipairs(device.Connections) do
		connection:Disconnect()
	end
	if device.Module.Detach then
		device.Module:Detach(device)
	end
end

local refreshDevice -- forward

local function track(flag: Instance)
	if devices[flag] or not flag:IsA("BoolValue") or flag.Name ~= CONFIG.FlagName then
		return
	end
	local root = resolveRoot(flag)
	if not root then
		return
	end
	local moduleName = root:GetAttribute("EWMenuModule")
	local module = modules[if type(moduleName) == "string" then moduleName else CONFIG.DefaultModule] or modules[CONFIG.DefaultModule]
	if not module then
		return
	end
	local nameAttr = root:GetAttribute("CustomDisplayName")
	local device: Device = {
		Flag = flag :: BoolValue,
		Root = root,
		Anchor = findAnchor(flag, root),
		DisplayName = if type(nameAttr) == "string" and nameAttr ~= "" then nameAttr else root.Name,
		Module = module,
		Points = {},
		PointsDirty = true,
		Connections = {},
		InRange = false,
	}
	devices[flag] = device
	local function markDirty(desc: Instance)
		if desc:IsA("Attachment") then
			-- Only author-placed points matter; the generated fallback point lives
			-- inside the root too, and rebuilding on it would loop every check.
			if desc.Name == CONFIG.PointAttachmentName or desc:GetAttribute("EWAction") ~= nil then
				device.PointsDirty = true
			end
		elseif desc:IsA("BasePart") then
			device.PointsDirty = true
		end
	end
	table.insert(device.Connections, root.DescendantAdded:Connect(markDirty))
	table.insert(device.Connections, root.DescendantRemoving:Connect(markDirty))
	if module.Attach then
		module:Attach(device)
	end
end

-- Discovery: one scan, then events (handles streaming in/out and respawns).
workspace.DescendantAdded:Connect(function(inst)
	if inst.ClassName == "BoolValue" and inst.Name == CONFIG.FlagName then
		task.defer(track, inst)
	end
end)
workspace.DescendantRemoving:Connect(function(inst)
	if devices[inst] then
		untrack(inst)
		-- Reparented within the world (e.g. gear moved between models)? Track again.
		task.defer(function()
			if inst.Parent and inst:IsDescendantOf(workspace) then
				track(inst)
			end
		end)
	end
end)
for _, inst in ipairs(workspace:GetDescendants()) do
	if inst.ClassName == "BoolValue" and inst.Name == CONFIG.FlagName then
		track(inst)
	end
end

--------------------------------------------------------------------------------
-- GUI behaviour
--------------------------------------------------------------------------------
local function connectHover(button: TextButton, selector: ImageLabel, onClick: () -> ())
	button.MouseEnter:Connect(function()
		if activeSelector and activeSelector ~= selector then
			activeSelector.Visible = false
		end
		activeSelector = selector
		selector.Visible = true
	end)
	button.MouseLeave:Connect(function()
		if activeSelector == selector then
			selector.Visible = false
			activeSelector = nil
		end
	end)
	button.Activated:Connect(function()
		clickSound:Play()
		onClick()
	end)
end

local function setLabel(button: Instance, text: string, color: Color3?)
	local object = button:FindFirstChild("Object") :: ImageLabel
	local title = object and object:FindFirstChild("Title") :: TextLabel
	if title then
		title.Text = text
	end
	if object and color then
		object.BackgroundColor3 = color -- the dot is drawn as the label's background
	end
end

local function clearList(frame: Instance)
	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
end

local fillSection -- forward

local function fillList(device: Device, point: Point, frame: Frame, entries, isThirdColumn: boolean)
	clearList(frame)
	local gui = point.Gui :: BillboardGui
	local third = gui:FindFirstChild("Interacts") :: Frame
	for _, entry in ipairs(entries) do
		local option = Templates.CreateOption()
		option.Name = entry.Id
		option.LayoutOrder = entry.Order or 0
		option.Visible = true
		setLabel(option, entry.Text)
		local object = option:FindFirstChild("Object") :: ImageLabel
		connectHover(option, object:FindFirstChild("Selector") :: ImageLabel, function()
			if entry.Children and not isThirdColumn then
				if point.Opened == entry.Id then
					point.Opened = nil
					third.Visible = false
					clearList(third)
				else
					point.Opened = entry.Id
					third.Visible = true
					fillList(device, point, third, entry.Children(), true)
				end
			elseif entry.Run then
				entry.Run()
			end
		end)
		option.Parent = frame
	end
end

fillSection = function(device: Device, point: Point)
	local gui = point.Gui
	if not gui then
		return
	end
	local section = gui:FindFirstChild("Section") :: Frame
	local third = gui:FindFirstChild("Interacts") :: Frame
	fillList(device, point, section, device.Module:Entries(point.Action, device), false)
	-- Keep an open third column in sync with fresh state.
	if point.Opened then
		local opened = nil
		for _, entry in ipairs(device.Module:Entries(point.Action, device)) do
			if entry.Id == point.Opened and entry.Children then
				opened = entry
			end
		end
		if opened then
			fillList(device, point, third, opened.Children(), true)
		else
			point.Opened = nil
			third.Visible = false
			clearList(third)
		end
	end
end

local function createPointGui(device: Device, point: Point)
	local gui = Templates.CreateBillboard()
	gui.Adornee = point.Attachment
	gui.Parent = playerGui
	point.Gui = gui
	local main = gui:FindFirstChild("Main") :: TextButton
	local object = main:FindFirstChild("Object") :: ImageLabel
	local section = gui:FindFirstChild("Section") :: Frame
	local third = gui:FindFirstChild("Interacts") :: Frame
	setLabel(main, device.Module:PointLabel(point.Action, device, point.Label), device.Module:PointColor(point.Action, device))
	connectHover(main, object:FindFirstChild("Selector") :: ImageLabel, function()
		if device.Module:OpensList(point.Action) then
			section.Visible = not section.Visible
			if section.Visible then
				fillSection(device, point)
				device.Module:RequestStatus(device, true)
			else
				third.Visible = false
				point.Opened = nil
			end
		else
			device.Module:Run(point.Action, device)
		end
	end)
	device.Module:RequestStatus(device, false)
end

refreshDevice = function(device: Device)
	for _, point in ipairs(device.Points) do
		local gui = point.Gui
		if gui then
			local main = gui:FindFirstChild("Main") :: TextButton
			setLabel(main, device.Module:PointLabel(point.Action, device, point.Label), device.Module:PointColor(point.Action, device))
			local section = gui:FindFirstChild("Section") :: Frame
			if section.Visible then
				fillSection(device, point)
			end
		end
	end
end

for _, module in pairs(modules) do
	if module.StatusChanged then
		module.StatusChanged:Connect(function(device)
			if devices[device.Flag] == device then
				refreshDevice(device)
			end
		end)
	end
end

local function hideDevice(device: Device)
	for _, point in ipairs(device.Points) do
		destroyPointGui(point)
	end
	device.InRange = false
end

local function clearMenus()
	for _, device in pairs(devices) do
		hideDevice(device)
	end
	if activeSelector then
		activeSelector.Visible = false
		activeSelector = nil
	end
end

-- The character can be replaced before CharacterAdded is connected (custom
-- character loaders), so re-resolve the root whenever the cached one is stale.
local function currentRoot(): BasePart?
	local current = player.Character
	if current ~= character or not (characterRoot and characterRoot:IsDescendantOf(workspace)) then
		character = current
		characterRoot = if current then current:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
	end
	return characterRoot
end

local function distanceTo(device: Device): number
	local root = currentRoot()
	local anchor = device.Anchor
	if not (root and anchor and anchor.Parent) then
		return math.huge
	end
	return (anchor.Position - root.Position).Magnitude
end

local function updateVisibility()
	for _, device in pairs(devices) do
		if not (device.Anchor and device.Anchor.Parent) then
			device.Anchor = findAnchor(device.Flag, device.Root)
			device.PointsDirty = true
		end
		local inRange = distanceTo(device) <= (device.Module.Settings and device.Module.Settings.Distance or 10)
		if inRange then
			if device.PointsDirty then
				buildPoints(device)
			end
			for _, point in ipairs(device.Points) do
				if not point.Gui and point.Attachment.Parent then
					createPointGui(device, point)
				end
			end
			device.InRange = true
			device.Module:RequestStatus(device, false)
		elseif device.InRange then
			hideDevice(device)
		end
	end
end

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------
local function setHolding(value: boolean)
	if holding == value then
		return
	end
	holding = value
	if holding then
		updateVisibility()
	else
		clearMenus()
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if table.find(CONFIG.HoldKeys, input.KeyCode) then
		setHolding(true)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if table.find(CONFIG.HoldKeys, input.KeyCode) then
		if not touchToggled then
			setHolding(false)
		end
	end
end)

if UserInputService.TouchEnabled then
	local toggle = Instance.new("TextButton")
	toggle.Name = "EWMenuToggle"
	toggle.AnchorPoint = Vector2.new(1, 1)
	toggle.Position = UDim2.new(1, -16, 1, -180)
	toggle.Size = UDim2.fromOffset(64, 40)
	toggle.BackgroundColor3 = Color3.fromRGB(18, 22, 18)
	toggle.BackgroundTransparency = 0.25
	toggle.TextColor3 = Color3.new(1, 1, 1)
	toggle.Font = Enum.Font.SourceSansBold
	toggle.TextSize = 18
	toggle.Text = "EW"
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = toggle
	toggle.Parent = screen
	toggle.Activated:Connect(function()
		touchToggled = not touchToggled
		toggle.Text = if touchToggled then "EW ON" else "EW"
		setHolding(touchToggled)
	end)
end

player.CharacterAdded:Connect(function(newCharacter)
	character = newCharacter
	characterRoot = newCharacter:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	clearMenus()
	holding = touchToggled
end)

local sinceCheck = 0
RunService.PreRender:Connect(function(dt)
	if holding then
		sinceCheck += dt
		if sinceCheck >= CONFIG.VisibilityCheckSeconds then
			sinceCheck = 0
			updateVisibility()
		end
	end
	if activeSelector then
		activeSelector.Rotation += CONFIG.SelectorDegreesPerSecond * dt
	end
end)
