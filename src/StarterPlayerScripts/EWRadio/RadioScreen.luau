--[[
	RadioScreen
	Builds the AN/PRC-163 front panel in code (no image assets) and renders a
	RadioState payload onto it. Layout follows the screen / keypad spec taken
	from the reference images (docs/RESEARCH_NOTES.md section 1):

	  status bar   XB:OFF          17:25:03          [#####.]
	  tabs         R/T 1 | R/T 2 (hatched when not selected) | MM
	  line         R  VOL ######   VULOS   NOI   VINSON
	  frequency    R:  142.50000                  TX [####  ]
	               T:  142.50000                  01
	  fields       LOS  VOC  AM  HIGH  01   (TYPE TRF MOD PWR KEY)
	  GPS          18S  MGRS-NEW / UJ 43773E 39055N
	  knob         < KNOB 01 >        keypad 4 x 4        PTT

	The controller owns input; this module only creates instances and draws.
]]

local RadioScreen = {}

local LCD = Color3.fromRGB(168, 200, 58)
local LCD_DIM = Color3.fromRGB(140, 168, 46)
local INK = Color3.fromRGB(18, 22, 10)
local BEZEL = Color3.fromRGB(34, 38, 30)
local BODY = Color3.fromRGB(62, 68, 48)
local KEY = Color3.fromRGB(26, 28, 24)
local MONO = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Medium)
local MONO_BOLD = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Bold)
local LABEL = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold, Enum.FontStyle.Italic)

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function text(parent: Instance, name: string, props): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.FontFace = props.Font or MONO
	label.TextColor3 = props.Color or INK
	label.TextSize = props.Size or 13
	label.TextXAlignment = props.AlignX or Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.RichText = true
	label.Text = props.Text or ""
	label.Position = props.Position or UDim2.new()
	label.Size = props.Dimensions or UDim2.new(1, 0, 0, 16)
	label.Parent = parent
	return label
end

local function button(parent: Instance, name: string, props): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.AutoButtonColor = true
	b.BackgroundColor3 = props.Color or KEY
	b.BorderSizePixel = 0
	b.FontFace = props.Font or MONO_BOLD
	b.TextColor3 = props.TextColor or Color3.fromRGB(235, 235, 225)
	b.TextSize = props.Size or 14
	b.RichText = true
	b.Text = props.Text or ""
	b.Position = props.Position or UDim2.new()
	b.Size = props.Dimensions or UDim2.fromOffset(60, 36)
	b.Parent = parent
	corner(b, props.Radius or 5)
	return b
end

-- Keypad legend: { key id, main glyph, sub label, colour? }
RadioScreen.Keys = {
	{ "1", "1", "ABC/CALL" },
	{ "2", "2", "DEF/LT" },
	{ "3", "3", "GHI/MODE" },
	{ "CLR", "CLR", "", Color3.fromRGB(150, 30, 30) },
	{ "4", "4", "JKL/SQL" },
	{ "5", "5", "MNO/ZERO" },
	{ "6", "6", "PQR/\u{25B2}" },
	{ "ENT", "ENT", "", Color3.fromRGB(30, 110, 40) },
	{ "7", "7", "STU/OPT" },
	{ "8", "8", "VWX/PGM" },
	{ "9", "9", "YZ?/\u{25BC}" },
	{ "PRE+", "PRE +", "" },
	{ "0", "0", "\u{25CB}" },
	{ "LEFT", "\u{25C0}", "" },
	{ "RIGHT", "\u{25B6}", "" },
	{ "PRE-", "PRE \u{2212}", "" },
}

function RadioScreen.Build(parent: Instance)
	local ui = { Keys = {} }

	local gui = Instance.new("ScreenGui")
	gui.Name = "EWRadio"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = parent
	ui.Gui = gui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(1, 1)
	panel.Position = UDim2.new(1, -16, 1, -16)
	panel.Size = UDim2.fromOffset(380, 600)
	panel.BackgroundColor3 = BODY
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = gui
	corner(panel, 14)
	local scale = Instance.new("UIScale")
	scale.Parent = panel
	ui.Panel = panel
	ui.Scale = scale

	-- Frees the mouse in first person while the radio is in hand.
	local modal = Instance.new("TextButton")
	modal.Name = "Modal"
	modal.BackgroundTransparency = 1
	modal.Text = ""
	modal.Size = UDim2.fromScale(0, 0)
	modal.Modal = true
	modal.Parent = panel

	text(panel, "Brand", { Text = "AN/PRC-163", Font = LABEL, Size = 18, Color = Color3.new(1, 1, 1), AlignX = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 8), Dimensions = UDim2.new(1, 0, 0, 22) })

	-- LCD
	local bezel = Instance.new("Frame")
	bezel.Name = "Bezel"
	bezel.Position = UDim2.fromOffset(14, 36)
	bezel.Size = UDim2.new(1, -28, 0, 232)
	bezel.BackgroundColor3 = BEZEL
	bezel.BorderSizePixel = 0
	bezel.Parent = panel
	corner(bezel, 8)
	local lcd = Instance.new("Frame")
	lcd.Name = "LCD"
	lcd.Position = UDim2.fromOffset(8, 8)
	lcd.Size = UDim2.new(1, -16, 1, -16)
	lcd.BackgroundColor3 = LCD
	lcd.BorderSizePixel = 0
	lcd.ClipsDescendants = true
	lcd.Parent = bezel
	corner(lcd, 3)
	ui.Lcd = lcd

	ui.Crossband = text(lcd, "Crossband", { Position = UDim2.fromOffset(6, 2), Dimensions = UDim2.fromOffset(80, 16) })
	ui.Clock = text(lcd, "Clock", { AlignX = Enum.TextXAlignment.Center, Position = UDim2.new(0, 0, 0, 2), Dimensions = UDim2.new(1, 0, 0, 16) })
	ui.Battery = text(lcd, "Battery", { AlignX = Enum.TextXAlignment.Right, Position = UDim2.new(0, 0, 0, 2), Dimensions = UDim2.new(1, -6, 0, 16) })

	-- Tabs: R/T 1, R/T 2, MM
	ui.Tabs = {}
	for i, name in ipairs({ "RT1", "RT2", "MM" }) do
		local tab = Instance.new("TextButton")
		tab.Name = name
		tab.AutoButtonColor = false
		tab.BorderSizePixel = 0
		tab.FontFace = MONO_BOLD
		tab.TextSize = 12
		tab.TextColor3 = INK
		tab.RichText = true
		tab.Position = UDim2.new((i - 1) * 0.36, 4, 0, 20)
		tab.Size = if i < 3 then UDim2.new(0.36, -6, 0, 18) else UDim2.new(0.28, -8, 0, 18)
		tab.Parent = lcd
		local stroke = Instance.new("UIStroke")
		stroke.Color = INK
		stroke.Thickness = 1
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = tab
		ui.Tabs[i] = tab
	end

	ui.Line = text(lcd, "Line", { Size = 12, Position = UDim2.fromOffset(6, 42), Dimensions = UDim2.new(1, -12, 0, 16) })
	ui.Rx = text(lcd, "Rx", { Font = MONO_BOLD, Size = 22, Position = UDim2.fromOffset(6, 60), Dimensions = UDim2.new(0.7, 0, 0, 26) })
	ui.Tx = text(lcd, "Tx", { Font = MONO_BOLD, Size = 22, Position = UDim2.fromOffset(6, 86), Dimensions = UDim2.new(0.7, 0, 0, 26) })
	ui.TxBar = text(lcd, "TxBar", { Size = 12, AlignX = Enum.TextXAlignment.Right, Position = UDim2.new(0.6, 0, 0, 64), Dimensions = UDim2.new(0.4, -6, 0, 18) })
	ui.Chan = text(lcd, "Chan", { Font = MONO_BOLD, Size = 18, AlignX = Enum.TextXAlignment.Right, Position = UDim2.new(0.6, 0, 0, 88), Dimensions = UDim2.new(0.4, -6, 0, 22) })
	ui.Preset = text(lcd, "Preset", { Size = 12, Position = UDim2.fromOffset(6, 112), Dimensions = UDim2.new(1, -12, 0, 14) })
	ui.Fields = text(lcd, "Fields", { Font = MONO_BOLD, Size = 13, Position = UDim2.fromOffset(6, 130), Dimensions = UDim2.new(1, -12, 0, 16) })
	ui.FieldLabels = text(lcd, "FieldLabels", { Size = 10, Color = Color3.fromRGB(60, 70, 20), Text = "TYPE  TRF   MOD   PWR   SQL   KEY", Position = UDim2.fromOffset(6, 146), Dimensions = UDim2.new(1, -12, 0, 12) })
	ui.Gps = text(lcd, "Gps", { Size = 12, Position = UDim2.fromOffset(6, 164), Dimensions = UDim2.new(1, -12, 0, 30) })
	ui.Gps.TextWrapped = true
	ui.Message = text(lcd, "Message", { Font = MONO_BOLD, Size = 12, Position = UDim2.fromOffset(6, 196), Dimensions = UDim2.new(1, -12, 0, 16) })

	-- Function knob
	local knobRow = Instance.new("Frame")
	knobRow.Name = "KnobRow"
	knobRow.BackgroundTransparency = 1
	knobRow.Position = UDim2.fromOffset(14, 276)
	knobRow.Size = UDim2.new(1, -28, 0, 34)
	knobRow.Parent = panel
	ui.KnobLeft = button(knobRow, "KnobLeft", { Text = "\u{25C0}", Dimensions = UDim2.fromOffset(40, 34) })
	ui.KnobLabel = text(knobRow, "Knob", { Font = MONO_BOLD, Size = 16, Color = Color3.new(1, 1, 1), AlignX = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(44, 0), Dimensions = UDim2.new(1, -88, 1, 0) })
	ui.KnobRight = button(knobRow, "KnobRight", { Text = "\u{25B6}", Position = UDim2.new(1, -40, 0, 0), Dimensions = UDim2.fromOffset(40, 34) })

	-- Keypad 4 x 4 + PTT bar
	local pad = Instance.new("Frame")
	pad.Name = "Keypad"
	pad.BackgroundTransparency = 1
	pad.Position = UDim2.fromOffset(14, 316)
	pad.Size = UDim2.new(1, -88, 0, 196)
	pad.Parent = panel
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(0.25, -6, 0, 44)
	grid.CellPadding = UDim2.fromOffset(6, 6)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = pad
	for i, spec in ipairs(RadioScreen.Keys) do
		local b = button(pad, "Key_" .. spec[1], {
			Text = if spec[3] ~= "" then string.format('%s\n<font size="9">%s</font>', spec[2], spec[3]) else spec[2],
			Color = spec[4],
			Size = 15,
		})
		b.LayoutOrder = i
		ui.Keys[spec[1]] = b
	end
	ui.Ptt = button(panel, "PTT", {
		Text = "P\nT\nT",
		Color = Color3.fromRGB(20, 22, 18),
		Size = 16,
		Position = UDim2.new(1, -66, 0, 316),
		Dimensions = UDim2.fromOffset(52, 194),
		Radius = 10,
	})

	-- Message entry + traffic log
	local input = Instance.new("TextBox")
	input.Name = "MessageInput"
	input.ClearTextOnFocus = false
	input.PlaceholderText = "Type a message, Enter to send on the selected R/T"
	input.Text = ""
	input.FontFace = MONO
	input.TextSize = 12
	input.TextXAlignment = Enum.TextXAlignment.Left
	input.TextColor3 = Color3.new(1, 1, 1)
	input.PlaceholderColor3 = Color3.fromRGB(170, 170, 160)
	input.BackgroundColor3 = KEY
	input.BorderSizePixel = 0
	input.Position = UDim2.fromOffset(14, 518)
	input.Size = UDim2.new(1, -28, 0, 28)
	input.Parent = panel
	corner(input, 5)
	local pad2 = Instance.new("UIPadding")
	pad2.PaddingLeft = UDim.new(0, 6)
	pad2.Parent = input
	ui.Input = input
	ui.Hint = text(panel, "Hint", {
		Size = 10,
		Color = Color3.fromRGB(205, 210, 190),
		Text = "Hold PTT (or Caps Lock) to key | knob FP + digits + ENT to tune",
		AlignX = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 552),
		Dimensions = UDim2.new(1, 0, 0, 14),
	})

	-- Traffic feed (visible with or without the panel: the radio receives in the
	-- backpack too). Bottom-right; the controller moves it left of an open panel.
	local feed = Instance.new("Frame")
	feed.Name = "Traffic"
	feed.AnchorPoint = Vector2.new(1, 1)
	feed.Position = UDim2.new(1, -16, 1, -16)
	feed.Size = UDim2.fromOffset(360, 220)
	feed.BackgroundTransparency = 1
	feed.Parent = gui
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.VerticalAlignment = Enum.VerticalAlignment.Bottom
	list.HorizontalAlignment = Enum.HorizontalAlignment.Right
	list.Padding = UDim.new(0, 4)
	list.Parent = feed
	ui.Feed = feed
	ui.FeedOrder = 0

	return ui
end

local function hatch(label: string): string
	return "\u{2571}\u{2571}" .. label .. "\u{2571}\u{2571}"
end

local function bar(fraction: number, cells: number, full: string, empty: string): string
	local n = math.clamp(math.floor(fraction * cells + 0.5), 0, cells)
	return string.rep(full, n) .. string.rep(empty, cells - n)
end

function RadioScreen.KnobText(knob: any): string
	if type(knob) == "number" then
		return string.format("KNOB  %02d", knob)
	end
	return "KNOB  " .. tostring(knob)
end

-- view = { State = RadioState payload, Entry = string?, Message = string?, Gps = {...}, Clock = string }
function RadioScreen.Render(ui, view)
	local state = view.State
	if not state then
		ui.Rx.Text = "R:  ----.-----"
		ui.Tx.Text = "T:  ----.-----"
		ui.Message.Text = "NO RADIO"
		return
	end
	local on = state.PowerState == "On"
	local booting = state.PowerState == "Booting"
	ui.Lcd.BackgroundColor3 = if on or booting then (if view.Backlight then Color3.fromRGB(190, 225, 70) else LCD) else Color3.fromRGB(70, 78, 50)
	ui.KnobLabel.Text = RadioScreen.KnobText(state.Knob)
	for _, child in ipairs(ui.Lcd:GetChildren()) do
		if child:IsA("TextLabel") or child:IsA("TextButton") then
			child.Visible = on or booting
		end
	end
	if booting then
		ui.Line.Text = ""
		ui.Rx.Text = "  BOOTING..."
		ui.Tx.Text = ""
		ui.Message.Text = ""
		return
	end
	if not on then
		return
	end

	local active = state.ActiveRt
	local channel = state.Channels[active]
	ui.Crossband.Text = if state.Crossband then "XB:ON" else "XB:OFF"
	ui.Clock.Text = view.Clock or ""
	ui.Battery.Text = if state.BatteryPercent then "[" .. bar(state.BatteryPercent / 100, 6, "\u{25A0}", "\u{25AF}") .. "]" else "[EXT]"
	for i = 1, 2 do
		local c = state.Channels[i]
		local label = string.format("%s  %s", c.Waveform, c.Comsec)
		ui.Tabs[i].Text = if i == active then label else hatch(label)
		ui.Tabs[i].BackgroundColor3 = if i == active then LCD else LCD_DIM
		ui.Tabs[i].BackgroundTransparency = 0
	end
	ui.Tabs[3].Text = hatch("MM")
	ui.Tabs[3].BackgroundColor3 = LCD_DIM

	local volume = bar(state.Volume / 8, 6, "\u{2587}", " ")
	local comsec = if channel.Comsec == "CT" then (if channel.KeyLoaded then "VINSON" else "NO KEY") else "NONE"
	ui.Line.Text = string.format("R  VOL %s  %-7s %-4s %s", volume, channel.Waveform, channel.Squelch, comsec)
	if view.Entry then
		ui.Rx.Text = "R:  " .. view.Entry .. "_"
		ui.Tx.Text = "T:  " .. view.Entry .. "_"
	else
		ui.Rx.Text = string.format("R:  %.5f", channel.RxMHz)
		ui.Tx.Text = string.format("T:  %.5f", channel.TxMHz)
	end
	ui.TxBar.Text = if channel.Transmitting then "TX [\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}]" else "TX [      ]"
	ui.Chan.Text = if channel.Preset then string.format("%02d", channel.Preset) else "---"
	ui.Preset.Text = channel.Label .. (if state.Zeroized then "   ZEROIZED" else "")
	ui.Fields.Text = string.format(
		"%-5s %-5s %-5s %-5s %-5s %s",
		"LOS",
		channel.Traffic,
		channel.Mod,
		channel.Power,
		channel.Squelch,
		if channel.Comsec == "CT" then string.format("%02d", channel.KeySlot) else "--"
	)
	local gps = view.Gps
	ui.Gps.Text = if gps then string.format("%s  MGRS-NEW\n%s %05dE %05dN", gps.Zone, gps.Square, gps.Easting, gps.Northing) else "GPS: NO FIX"
	ui.Message.Text = view.Message or ""
end

-- Adds one line to the traffic feed (newest at the bottom, keeps the last 5).
function RadioScreen.AddTraffic(ui, line: string, color: Color3?)
	ui.FeedOrder += 1
	local label = Instance.new("TextLabel")
	label.Name = "Line"
	label.LayoutOrder = ui.FeedOrder
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.Size = UDim2.new(1, 0, 0, 0)
	label.BackgroundColor3 = Color3.fromRGB(14, 16, 12)
	label.BackgroundTransparency = 0.25
	label.FontFace = MONO
	label.TextSize = 13
	label.TextWrapped = true
	label.RichText = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = color or LCD
	label.Text = line
	label.Parent = ui.Feed
	corner(label, 4)
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 6)
	padding.PaddingRight = UDim.new(0, 6)
	padding.PaddingTop = UDim.new(0, 3)
	padding.PaddingBottom = UDim.new(0, 3)
	padding.Parent = label
	local lines = {}
	for _, child in ipairs(ui.Feed:GetChildren()) do
		if child:IsA("TextLabel") then
			table.insert(lines, child)
		end
	end
	table.sort(lines, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for i = 1, #lines - 5 do
		lines[i]:Destroy()
	end
	task.delay(20, function()
		if label.Parent then
			label:Destroy()
		end
	end)
end

return RadioScreen
