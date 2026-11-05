--[[
	EWGearIssue (Script)
	Hands out EW equipment Tools (Phase 2: the AN/PRC-163).

	Any Model in Workspace with the attribute EWIssueTool = "<Tool name>"
	becomes a pickup: its ProximityPrompt gives the player a copy of
	ServerStorage.EWGear.<Tool name>. One copy per player (Backpack or hand);
	taking again while you already have one does nothing. The copy gets
	EWSerial = "<Tool name>:<UserId>", so its EW state (battery, radio
	programming, COMSEC keys) follows that player across respawns.

	The display model itself stays in place.
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local STATION_ATTRIBUTE = "EWIssueTool"
local GEAR_FOLDER = "EWGear"
local DEBOUNCE_SECONDS = 0.75

local lastUse: { [Player]: number } = {}

local function templateFor(name: string): Tool?
	local folder = ServerStorage:FindFirstChild(GEAR_FOLDER)
	local tool = folder and folder:FindFirstChild(name)
	return if tool and tool:IsA("Tool") then tool else nil
end

local function alreadyHas(player: Player, name: string): boolean
	local backpack = player:FindFirstChildOfClass("Backpack")
	return (backpack ~= nil and backpack:FindFirstChild(name) ~= nil)
		or (player.Character ~= nil and player.Character:FindFirstChild(name) ~= nil)
end

local function issue(player: Player, name: string)
	local now = os.clock()
	if (lastUse[player] or 0) + DEBOUNCE_SECONDS > now then
		return
	end
	lastUse[player] = now
	local template = templateFor(name)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not (template and backpack) or alreadyHas(player, name) then
		return
	end
	local tool = template:Clone()
	tool:SetAttribute("EWSerial", name .. ":" .. player.UserId)
	tool.Parent = backpack
end

local function promptPartOf(station: Model): BasePart?
	if station.PrimaryPart then
		return station.PrimaryPart
	end
	local best, bestVolume = nil, -1
	for _, d in ipairs(station:GetDescendants()) do
		if d:IsA("BasePart") then
			local volume = d.Size.X * d.Size.Y * d.Size.Z
			if volume > bestVolume then
				best, bestVolume = d, volume
			end
		end
	end
	return best
end

local function setupStation(station: Instance)
	if not station:IsA("Model") then
		return
	end
	local name = station:GetAttribute(STATION_ATTRIBUTE)
	if type(name) ~= "string" or station:FindFirstChild("EWIssuePrompt", true) then
		return
	end
	local part = promptPartOf(station)
	if not part then
		return
	end
	local point = Instance.new("Attachment")
	point.Name = "EWIssuePoint"
	point.Parent = part
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "EWIssuePrompt"
	prompt.ActionText = "Take"
	prompt.ObjectText = name
	prompt.HoldDuration = 0.3
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = point
	prompt.Triggered:Connect(function(player)
		issue(player, name)
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
