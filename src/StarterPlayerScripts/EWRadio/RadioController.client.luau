--[[
	EW Radio - Controller (LocalScript)
	Phase 2 client for the AN/PRC-163 Tool. Equipping the radio opens its front
	panel; the radio keeps receiving while it sits in the Backpack (incoming
	traffic shows in the feed top-right).

	CONTROLS (mouse on the panel)
	  Knob < >      OFF / Z (zeroize, click twice) / LOAD (key fill) / FP / 01..15
	  digits        knob FP: type a frequency, RIGHT arrow = decimal point, LEFT arrow =
	                backspace, ENT applies it to the selected R/T (CLR cancels)
	  LEFT / RIGHT  without an entry: select R/T 1 / R/T 2
	  PRE + / -     next / previous preset on the selected R/T
	  3 MODE        power LOW / MED / HIGH        4 SQL   squelch NOI / TON / OFF
	  5 ZERO        zeroize (click twice)          7 OPT   COMSEC PT / CT
	  6 UP / 9 DOWN volume                         2 LT    backlight
	  8 PGM         list the programmed presets   1 CALL  radio check (sends "RADIO CHECK")
	  PTT           hold (or hold Caps Lock) to key the selected R/T
	  Message box   Enter sends a text burst on the selected R/T

	The client only REQUESTS. RadioService validates every command and replies
	with the authoritative RadioState.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("EWShared")
local EWRemotes = require(Shared:WaitForChild("EWRemotes"))
local EWConfig = require(Shared:WaitForChild("EWConfig"))
local RadioDefinitions = require(Shared:WaitForChild("RadioDefinitions"))
local RadioScreen = require(script.Parent:WaitForChild("RadioScreen"))

local commandRemote = EWRemotes.Get("RadioCommand") :: RemoteEvent?
local stateRemote = EWRemotes.Get("RadioState") :: RemoteEvent?
local trafficRemote = EWRemotes.Get("RadioTraffic") :: RemoteEvent?

local CONFIG = {
	PttKey = Enum.KeyCode.CapsLock,
	MessageSeconds = 3,
	ConfirmSeconds = 2.5,
}

local RADIO = RadioDefinitions.PRC163
local KNOB_ORDER: { any } = { "OFF", "Z", "LOAD", "FP" }
for n = 1, RADIO.KnobPresets do
	table.insert(KNOB_ORDER, n)
end

local ui = RadioScreen.Build(player:WaitForChild("PlayerGui"))

local equipped: Tool? = nil -- radio in hand
local states: { [Instance]: any } = {} -- tool -> last RadioState
local entry: string? = nil -- frequency being typed
local message: string? = nil
local messageUntil = 0
local pendingConfirm: string? = nil
local confirmUntil = 0
local backlight = false
local pttHeld = false

local function isRadioTool(inst: Instance?): boolean
	return inst ~= nil and inst:IsA("Tool") and inst:GetAttribute("ElectronicType") == "PRC163"
end

local function send(action: string, extra: { [string]: any }?)
	if not (commandRemote and equipped) then
		return
	end
	local payload = { Action = action, Device = equipped }
	if extra then
		for k, v in pairs(extra) do
			payload[k] = v
		end
	end
	commandRemote:FireServer(payload)
end

local function flash(text: string)
	message = text
	messageUntil = os.clock() + CONFIG.MessageSeconds
end

local function currentState()
	return if equipped then states[equipped] else nil
end

local function gpsFix()
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return nil
	end
	local metersPerStud = EWConfig.Units.MetersPerStud * EWConfig.Units.RangeScale
	local p = hrp.Position
	return {
		Zone = "18S",
		Square = "UJ",
		Easting = math.floor(43773 + p.X * metersPerStud) % 100000,
		Northing = math.floor(39055 - p.Z * metersPerStud) % 100000,
	}
end

local function render()
	if os.clock() > messageUntil then
		message = nil
	end
	if os.clock() > confirmUntil then
		pendingConfirm = nil
	end
	RadioScreen.Render(ui, {
		State = currentState(),
		Entry = entry,
		Message = message,
		Gps = gpsFix(),
		Clock = os.date("!%H:%M:%SZ"),
		Backlight = backlight,
	})
end

--------------------------------------------------------------------------------
-- Equip tracking
--------------------------------------------------------------------------------

local function setEquipped(tool: Tool?)
	if equipped == tool then
		return
	end
	if equipped and pttHeld then
		pttHeld = false
		send("PttUp")
	end
	equipped = tool
	entry = nil
	ui.Panel.Visible = tool ~= nil
	if tool then
		send("Query")
	end
	render()
end

local function watchCharacter(character: Model)
	local function scan()
		local found = nil
		for _, child in ipairs(character:GetChildren()) do
			if isRadioTool(child) then
				found = child
			end
		end
		setEquipped(found)
	end
	character.ChildAdded:Connect(scan)
	character.ChildRemoved:Connect(scan)
	scan()
end

if player.Character then
	watchCharacter(player.Character)
end
player.CharacterAdded:Connect(watchCharacter)

--------------------------------------------------------------------------------
-- Server replies
--------------------------------------------------------------------------------

if stateRemote then
	stateRemote.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or typeof(payload.Device) ~= "Instance" then
			return
		end
		states[payload.Device] = payload
		if payload.Message and payload.Device == equipped then
			flash(string.upper(payload.Message))
		end
		render()
	end)
end

local STATE_COLORS = {
	Clear = Color3.fromRGB(168, 230, 90),
	Good = Color3.fromRGB(168, 230, 90),
	Degraded = Color3.fromRGB(255, 210, 74),
	Broken = Color3.fromRGB(255, 138, 31),
	Unusable = Color3.fromRGB(255, 90, 80),
}

if trafficRemote then
	trafficRemote.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or type(payload.Text) ~= "string" then
			return
		end
		local channel = string.format("R/T%d %s %.3f", payload.Rt or 0, tostring(payload.Label or ""), payload.FrequencyMHz or 0)
		if payload.Sent then
			RadioScreen.AddTraffic(ui, string.format("<b>TX</b> %s  %s", channel, payload.Text), Color3.fromRGB(200, 200, 190))
			return
		end
		local strength = if payload.Readability then string.format("  (%d/%d)", payload.Readability, payload.Strength or 0) else ""
		local from = if payload.Encrypted then "" else string.format("<b>%s</b>: ", tostring(payload.From))
		RadioScreen.AddTraffic(ui, string.format("%s  %s%s%s", channel, from, payload.Text, strength), STATE_COLORS[payload.State] or nil)
	end)
end

--------------------------------------------------------------------------------
-- Panel input
--------------------------------------------------------------------------------

local function confirm(id: string, prompt: string): boolean
	if pendingConfirm == id and os.clock() <= confirmUntil then
		pendingConfirm = nil
		return true
	end
	pendingConfirm = id
	confirmUntil = os.clock() + CONFIG.ConfirmSeconds
	flash(prompt)
	return false
end

-- Typed digits -> MHz. "45" -> 45, "142.5" -> 142.5.
local function parseEntry(digits: string): number?
	if digits == "" or digits == "." then
		return nil
	end
	return tonumber(digits)
end

local function pressKey(id: string)
	local state = currentState()
	if not state then
		return
	end
	if state.PowerState ~= "On" then
		flash("RADIO OFF")
		render()
		return
	end
	local isDigit = string.match(id, "^%d$") ~= nil
	if entry ~= nil or (isDigit and state.Knob == "FP") then
		entry = entry or ""
		if isDigit then
			if #entry < 10 then
				entry ..= id
			end
		elseif id == "RIGHT" then
			if not string.find(entry, ".", 1, true) then
				entry ..= "."
			end
		elseif id == "LEFT" then
			entry = string.sub(entry, 1, -2)
		elseif id == "CLR" then
			entry = nil
		elseif id == "ENT" then
			local mhz = parseEntry(entry)
			entry = nil
			if mhz then
				send("Frequency", { Number = mhz, Rt = state.ActiveRt })
			end
		end
		render()
		return
	end
	-- Outside FP entry the digit keys act as their function legends.
	if id == "1" then
		send("Text", { Text = "RADIO CHECK, OVER", Rt = state.ActiveRt })
	elseif id == "2" then
		backlight = not backlight
	elseif id == "3" then
		send("Power", { Rt = state.ActiveRt })
	elseif id == "4" then
		send("Squelch", { Rt = state.ActiveRt })
	elseif id == "5" then
		if confirm("ZERO", "ZEROIZE? PRESS 5 AGAIN") then
			send("Zeroize")
		end
	elseif id == "6" then
		send("Volume", { Number = 1 })
	elseif id == "9" then
		send("Volume", { Number = -1 })
	elseif id == "7" then
		send("Comsec", { Rt = state.ActiveRt })
	elseif id == "8" then
		local names = {}
		for _, preset in ipairs(RadioDefinitions.PresetsFor(state.ActiveRt)) do
			table.insert(names, RadioDefinitions.PresetLabel(preset))
		end
		RadioScreen.AddTraffic(ui, "PGM  R/T" .. state.ActiveRt .. " PRESETS: " .. table.concat(names, "  "), Color3.fromRGB(200, 200, 190))
	elseif id == "LEFT" then
		send("SelectRt", { Rt = 1 })
	elseif id == "RIGHT" then
		send("SelectRt", { Rt = 2 })
	elseif id == "PRE+" then
		send("PresetStep", { Number = 1, Rt = state.ActiveRt })
	elseif id == "PRE-" then
		send("PresetStep", { Number = -1, Rt = state.ActiveRt })
	elseif id == "CLR" then
		message = nil
	elseif id == "ENT" then
		send("Query")
	elseif id == "0" and state.Knob ~= "FP" then
		flash("SET KNOB TO FP TO TUNE")
	end
	render()
end

for id, b in pairs(ui.Keys) do
	b.Activated:Connect(function()
		pressKey(id)
	end)
end

local function turnKnob(direction: number)
	local state = currentState()
	if not state then
		return
	end
	local index = table.find(KNOB_ORDER, state.Knob) or 1
	local nextIndex = math.clamp(index + direction, 1, #KNOB_ORDER)
	local target = KNOB_ORDER[nextIndex]
	if target == "Z" and not confirm("KNOBZ", "PULL KNOB: TURN AGAIN TO ZEROIZE") then
		render()
		return
	end
	entry = nil
	if type(target) == "number" then
		send("Knob", { Number = target })
	else
		send("Knob", { Value = target })
	end
end
ui.KnobLeft.Activated:Connect(function()
	turnKnob(-1)
end)
ui.KnobRight.Activated:Connect(function()
	turnKnob(1)
end)

for i = 1, 2 do
	ui.Tabs[i].Activated:Connect(function()
		send("SelectRt", { Rt = i })
	end)
end

local function setPtt(down: boolean)
	local state = currentState()
	if down == pttHeld or not state then
		return
	end
	pttHeld = down
	send(if down then "PttDown" else "PttUp", { Rt = state.ActiveRt })
	ui.Ptt.BackgroundColor3 = if down then Color3.fromRGB(150, 30, 30) else Color3.fromRGB(20, 22, 18)
end
ui.Ptt.MouseButton1Down:Connect(function()
	setPtt(true)
end)
ui.Ptt.MouseButton1Up:Connect(function()
	setPtt(false)
end)
ui.Ptt.MouseLeave:Connect(function()
	setPtt(false)
end)
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and equipped and input.KeyCode == CONFIG.PttKey then
		setPtt(true)
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == CONFIG.PttKey then
		setPtt(false)
	end
end)

ui.Input.FocusLost:Connect(function(enterPressed)
	local state = currentState()
	local text = ui.Input.Text
	if enterPressed and state and not string.match(text, "^%s*$") then
		send("Text", { Text = string.sub(text, 1, RADIO.TextMaxLength), Rt = state.ActiveRt })
		ui.Input.Text = ""
	end
end)

-- Fit the panel on small screens and keep the traffic feed beside it.
local function layoutFeed()
	local offset = if ui.Panel.Visible then 16 + ui.Panel.AbsoluteSize.X + 12 else 16
	ui.Feed.Position = UDim2.new(1, -offset, 1, -16)
end

local function rescale()
	local camera = workspace.CurrentCamera
	if camera then
		local height = camera.ViewportSize.Y
		ui.Scale.Scale = math.clamp((height - 40) / 620, 0.55, 1)
	end
	layoutFeed()
end
ui.Panel:GetPropertyChangedSignal("Visible"):Connect(layoutFeed)
ui.Panel:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutFeed)
rescale()
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(rescale)
if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
end

local sinceRender = 0
RunService.Heartbeat:Connect(function(dt)
	if not equipped then
		return
	end
	sinceRender += dt
	if sinceRender >= 0.25 then
		sinceRender = 0
		render()
	end
end)
