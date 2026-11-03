--[[
	EWDebugPathRenderer (developer client only)
	Draws signal paths and obstruction points received from the server as
	LOCAL parts under workspace.CurrentCamera. Parts parented to the camera are
	not replicated, so other players never see them.

	Colors follow the link quality state; small cubes mark structure entry
	points (white = direct ray, grey = Fresnel spindle ray); the red diamond is
	the principal diffraction edge.
]]

local Renderer = {}

local folder: Folder? = nil

local STATE_COLORS = {
	Clear = Color3.fromRGB(124, 252, 0),
	Good = Color3.fromRGB(173, 255, 47),
	Degraded = Color3.fromRGB(255, 215, 0),
	Broken = Color3.fromRGB(255, 165, 0),
	Unusable = Color3.fromRGB(255, 90, 31),
	NoSignal = Color3.fromRGB(255, 48, 48),
	Incompatible = Color3.fromRGB(255, 102, 204),
	Offline = Color3.fromRGB(138, 138, 138),
}

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "EWDebugPaths"
	f.Parent = workspace.CurrentCamera
	folder = f
	return f
end

local function basePart(): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

local function line(parent: Instance, a: Vector3, b: Vector3, color: Color3, width: number)
	local length = (b - a).Magnitude
	if length < 0.05 then
		return
	end
	local p = basePart()
	p.Size = Vector3.new(width, width, length)
	p.CFrame = CFrame.lookAt((a + b) / 2, b)
	p.Color = color
	p.Transparency = 0.35
	p.Parent = parent
end

local function marker(parent: Instance, position: Vector3, color: Color3, size: number, rotate: boolean?)
	local p = basePart()
	p.Size = Vector3.new(size, size, size)
	p.CFrame = CFrame.new(position) * (if rotate then CFrame.Angles(math.rad(45), 0, math.rad(45)) else CFrame.identity)
	p.Color = color
	p.Transparency = 0.1
	p.Parent = parent
end

function Renderer.Clear()
	if folder then
		folder:ClearAllChildren()
	end
end

function Renderer.Render(paths)
	local root = getFolder()
	root:ClearAllChildren()
	if type(paths) ~= "table" then
		return
	end
	for _, path in ipairs(paths) do
		if typeof(path.A) == "Vector3" and typeof(path.B) == "Vector3" then
			local color = STATE_COLORS[path.State] or Color3.new(1, 1, 1)
			line(root, path.A, path.B, color, 0.35)
			for _, o in ipairs(path.Obstacles or {}) do
				if typeof(o.Entry) == "Vector3" then
					marker(root, o.Entry, if o.Center then Color3.new(1, 1, 1) else Color3.fromRGB(150, 150, 150), if o.Center then 1.2 else 0.7)
				end
			end
			if typeof(path.Edge) == "Vector3" then
				marker(root, path.Edge, Color3.fromRGB(255, 40, 40), 3, true)
				-- Vertical tick from the line of sight up to the edge top.
				local t = (path.Edge - path.A):Dot(path.B - path.A) / math.max((path.B - path.A).Magnitude ^ 2, 1e-6)
				local onLine = path.A:Lerp(path.B, math.clamp(t, 0, 1))
				line(root, Vector3.new(path.Edge.X, onLine.Y, path.Edge.Z), path.Edge, Color3.fromRGB(255, 40, 40), 0.2)
			end
		end
	end
end

return Renderer
