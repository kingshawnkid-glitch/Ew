--[[
	EWSecurityService
	Every client request passes through here. Clients can only REQUEST; the
	server decides using its own authoritative state.

	Protections
	  * Per-player, per-remote token-bucket rate limits (EWConfig.Security.RateLimits)
	  * Strict payload schemas: table shape, field types, enum values, string
	    lengths, no unexpected keys
	  * Device control authorization: carried devices only by their carrier;
	    world devices only within InteractionDistance of the player's character
	    (server-side positions, never client-supplied)
	  * Developer-only diagnostics (Studio, place creator, allowlist, group rank)
	  * Rejection counters per reason for diagnostics (Test J)

	The player attribute "EWDeveloper" (bool) is set by the server so the client
	knows whether to load the diagnostics UI. It grants nothing by itself: every
	diagnostics request is re-checked here.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("EWShared")
local SharedUtilities = require(Shared.SharedUtilities)

local Security = {}

Security.Rejected = SharedUtilities.Signal.new("SecurityRejected")

local context
local config
local buckets: { [Player]: { [string]: any } } = {}
local developers: { [Player]: boolean } = {}
local rejections: { [string]: number } = {}
local totalRejections = 0
local bag = SharedUtilities.ConnectionBag.new()

export type FieldSpec = {
	Type: string, -- Luau typeof() name: "string" | "number" | "boolean" | "Instance" | "Vector3" ...
	Optional: boolean?,
	Enum: { string }?,
	MaxLength: number?,
	Min: number?,
	Max: number?,
	Finite: boolean?,
}

function Security:Init(ctx)
	context = ctx
	config = ctx.Config
end

local function computeDeveloper(player: Player): boolean
	local s = config.Security
	if s.StudioUsersAreDevelopers and RunService:IsStudio() then
		return true
	end
	if table.find(s.DeveloperUserIds, player.UserId) then
		return true
	end
	if s.CreatorIsDeveloper then
		if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
			return true
		end
		if game.CreatorType == Enum.CreatorType.Group then
			local ok, rank = pcall(function()
				return player:GetRankInGroup(game.CreatorId)
			end)
			if ok and rank >= 255 then
				return true
			end
		end
	end
	if s.DeveloperGroupId and s.DeveloperGroupId > 0 then
		local ok, rank = pcall(function()
			return player:GetRankInGroup(s.DeveloperGroupId)
		end)
		if ok and rank >= s.DeveloperMinRank then
			return true
		end
	end
	return false
end

local function onPlayerAdded(player: Player)
	buckets[player] = {}
	developers[player] = false
	task.spawn(function()
		local isDev = computeDeveloper(player)
		if player.Parent then
			developers[player] = isDev
			player:SetAttribute("EWDeveloper", isDev)
		end
	end)
end

function Security:Start()
	bag:Add(Players.PlayerAdded:Connect(onPlayerAdded))
	bag:Add(Players.PlayerRemoving:Connect(function(player)
		buckets[player] = nil
		developers[player] = nil
	end))
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
end

function Security:IsDeveloper(player: Player): boolean
	return developers[player] == true
end

function Security:CheckRate(player: Player, remoteName: string): boolean
	local perPlayer = buckets[player]
	if not perPlayer then
		perPlayer = {}
		buckets[player] = perPlayer
	end
	local bucket = perPlayer[remoteName]
	if not bucket then
		local limits = config.Security.RateLimits[remoteName] or { Capacity = 5, RefillPerSecond = 1 }
		bucket = SharedUtilities.TokenBucket.new(limits.Capacity, limits.RefillPerSecond)
		perPlayer[remoteName] = bucket
	end
	return bucket:TryTake(1)
end

function Security:Reject(player: Player?, remoteName: string, reason: string)
	totalRejections += 1
	local key = remoteName .. ":" .. reason
	rejections[key] = (rejections[key] or 0) + 1
	Security.Rejected:Fire(player, remoteName, reason)
	if context.Diagnostics then
		context.Diagnostics:Warn(
			"Security",
			string.format("Rejected %s from %s: %s", remoteName, if player then player.Name else "?", reason)
		)
	end
end

function Security:ValidatePayload(payload: any, schema: { [string]: FieldSpec }): (boolean, string?)
	if type(payload) ~= "table" then
		return false, "PAYLOAD_NOT_TABLE"
	end
	-- Reject unexpected keys and metatables (clients cannot send metatables, but be explicit).
	if getmetatable(payload) ~= nil then
		return false, "PAYLOAD_METATABLE"
	end
	local keys = 0
	for key in pairs(payload) do
		keys += 1
		if type(key) ~= "string" or schema[key] == nil then
			return false, "UNEXPECTED_FIELD"
		end
		if keys > 16 then
			return false, "TOO_MANY_FIELDS"
		end
	end
	for name, spec in pairs(schema) do
		local value = payload[name]
		if value == nil then
			if not spec.Optional then
				return false, "MISSING_" .. string.upper(name)
			end
		else
			if typeof(value) ~= spec.Type then
				return false, "BAD_TYPE_" .. string.upper(name)
			end
			if spec.Type == "string" then
				local maxLength = spec.MaxLength or config.Security.MaxStringLength
				if #value > maxLength then
					return false, "STRING_TOO_LONG_" .. string.upper(name)
				end
				if spec.Enum and not table.find(spec.Enum, value) then
					return false, "BAD_ENUM_" .. string.upper(name)
				end
			elseif spec.Type == "number" then
				if value ~= value or value == math.huge or value == -math.huge then
					return false, "NON_FINITE_" .. string.upper(name)
				end
				if spec.Min and value < spec.Min then
					return false, "OUT_OF_RANGE_" .. string.upper(name)
				end
				if spec.Max and value > spec.Max then
					return false, "OUT_OF_RANGE_" .. string.upper(name)
				end
			end
		end
	end
	return true, nil
end

-- Authorization for commanding a device (power, configuration).
function Security:CanControlDevice(player: Player, record): (boolean, string?)
	if record.OwnerUserId ~= nil then
		if record.OwnerUserId == player.UserId then
			return true, nil
		end
		return false, "NOT_OWNER"
	end
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return false, "NO_CHARACTER"
	end
	local distance = (hrp.Position - record.Position).Magnitude
	if distance > config.Security.InteractionDistanceStuds then
		return false, "OUT_OF_RANGE"
	end
	local faction = record.Faction
	if faction and config.Security.EnforceFactions and player.Team and player.Team.Name ~= faction then
		return false, "WRONG_FACTION"
	end
	return true, nil
end

function Security:GetStats()
	local developerCount = 0
	for _, isDev in pairs(developers) do
		if isDev then
			developerCount += 1
		end
	end
	return {
		TotalRejections = totalRejections,
		Rejections = table.clone(rejections),
		Developers = developerCount,
	}
end

return Security
