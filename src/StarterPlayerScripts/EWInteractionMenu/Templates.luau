--[[
	Templates
	Builds the Interaction Menu GUI pieces in code, using the exact layout values
	decoded from the original "INTERACTION MENU" model (BillboardGui "Interact",
	"Main" button, "Section"/"Interacts" lists and the option "Template"), so the
	look matches: a white dot, a red rotating selector ring on hover, and a white
	label with a soft stroke. No template instances or binary assets are needed.

	EW additions: RichText titles (coloured state tags) and a tintable dot.
]]

local Templates = {}

Templates.DotImage = "rbxassetid://14938897283"
Templates.SelectorImage = "rbxassetid://117671255762193"
Templates.ClickSoundId = "rbxassetid://6324790483"

local FONT = Font.new("rbxasset://fonts/families/SourceSansPro.json", Enum.FontWeight.Regular, Enum.FontStyle.Normal)

local function list(parent: Instance, vertical: Enum.VerticalAlignment)
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 5)
	layout.Parent = parent
end

local function listFrame(name: string, position: UDim2, vertical: Enum.VerticalAlignment): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Position = position
	frame.Size = UDim2.new(0.1, 0, 0.1, 0)
	frame.SizeConstraint = Enum.SizeConstraint.RelativeXX
	frame.Visible = false
	list(frame, vertical)
	return frame
end

-- The dot + selector + title group shared by the main button and option rows.
local function decorate(button: TextButton)
	local object = Instance.new("ImageLabel")
	object.Name = "Object"
	object.AnchorPoint = Vector2.new(0.5, 0.5)
	object.BackgroundTransparency = 1
	object.BorderSizePixel = 0
	object.Image = Templates.DotImage
	object.ImageColor3 = Color3.new(1, 1, 1)
	object.Position = UDim2.new(0.2, 0, 0.5, 0)
	object.Size = UDim2.new(0.09, 0, 0.09, 0)
	object.SizeConstraint = Enum.SizeConstraint.RelativeXX
	object.ScaleType = Enum.ScaleType.Stretch
	object.Parent = button

	local selector = Instance.new("ImageLabel")
	selector.Name = "Selector"
	selector.AnchorPoint = Vector2.new(0.5, 0.5)
	selector.BackgroundTransparency = 1
	selector.BorderSizePixel = 0
	selector.Image = Templates.SelectorImage
	selector.ImageColor3 = Color3.fromRGB(255, 0, 4)
	selector.Position = UDim2.new(0.5, 0, 0.5, 0)
	selector.Size = UDim2.new(2, 0, 2, 0)
	selector.Visible = false
	selector.ZIndex = 2
	selector.Parent = object

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.BackgroundTransparency = 1
	title.BorderSizePixel = 0
	title.FontFace = FONT
	title.Position = UDim2.new(5.464, 0, 0.5, 0)
	title.Size = UDim2.new(8.101, 0, 1.2, 0)
	title.Text = "Object"
	title.RichText = true
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextScaled = true
	title.TextSize = 14
	title.TextStrokeColor3 = Color3.new(0, 0, 0)
	title.TextStrokeTransparency = 0.7
	title.TextWrapped = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextYAlignment = Enum.TextYAlignment.Center
	title.Parent = object

	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MaxTextSize = 15
	constraint.MinTextSize = 1
	constraint.Parent = title
end

local function baseButton(name: string, size: UDim2): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.AnchorPoint = Vector2.new(0.2, 0.5)
	button.AutoButtonColor = true
	button.BackgroundTransparency = 1
	button.BorderSizePixel = 0
	button.FontFace = FONT
	button.Position = UDim2.new(0.5, 0, 0.5, 0)
	button.Size = size
	button.Text = ""
	button.TextSize = 14
	decorate(button)
	return button
end

-- One interaction point: BillboardGui with the main button and two list levels.
function Templates.CreateBillboard(): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "EWInteract"
	gui.Active = true
	gui.AlwaysOnTop = true
	gui.ClipsDescendants = true
	gui.LightInfluence = 0
	gui.MaxDistance = 100
	gui.ResetOnSpawn = false
	gui.Size = UDim2.new(20, 0, 20, 0)
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Global

	listFrame("Interacts", UDim2.new(0.77, 0, 0.5, 0), Enum.VerticalAlignment.Top).Parent = gui
	listFrame("Section", UDim2.new(0.65, 0, 0.5, 0), Enum.VerticalAlignment.Center).Parent = gui
	baseButton("Main", UDim2.new(0.1, 0, 0.02, 0)).Parent = gui
	return gui
end

-- One row in the Section / Interacts lists.
function Templates.CreateOption(): TextButton
	return baseButton("Option", UDim2.new(1, 0, 0.2, 0))
end

return Templates
