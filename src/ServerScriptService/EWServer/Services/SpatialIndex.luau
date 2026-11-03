--[[
	SpatialIndex
	Uniform XZ spatial hash used for candidate filtering (interference sources,
	nearby devices, future electronic-support scans). It answers "which devices
	could matter here" cheaply; it never decides whether a link works - the RF
	engine does that with the full propagation model.

	API
	  SpatialIndex.new(cellSize) -> index
	  index:Update(id, position)   insert or move
	  index:Remove(id)
	  index:QueryRadius(position, radius, out?) -> { id }   (cell-conservative)
	  index:Count() -> number
]]

local SpatialIndex = {}
SpatialIndex.__index = SpatialIndex

local OFFSET = 524288 -- 2^19, keeps cell coordinates positive for numeric keys
local STRIDE = 1048576 -- 2^20

local function cellKey(cx: number, cz: number): number
	return (cx + OFFSET) * STRIDE + (cz + OFFSET)
end

function SpatialIndex.new(cellSize: number)
	return setmetatable({
		CellSize = cellSize,
		Cells = {} :: { [number]: { [string]: boolean } },
		ItemCell = {} :: { [string]: number },
		ItemPosition = {} :: { [string]: Vector3 },
		Items = 0,
	}, SpatialIndex)
end

function SpatialIndex:Update(id: string, position: Vector3)
	local cs = self.CellSize
	local key = cellKey(math.floor(position.X / cs), math.floor(position.Z / cs))
	self.ItemPosition[id] = position
	local old = self.ItemCell[id]
	if old == key then
		return
	end
	if old then
		local bucket = self.Cells[old]
		if bucket then
			bucket[id] = nil
			if next(bucket) == nil then
				self.Cells[old] = nil
			end
		end
	else
		self.Items += 1
	end
	local bucket = self.Cells[key]
	if not bucket then
		bucket = {}
		self.Cells[key] = bucket
	end
	bucket[id] = true
	self.ItemCell[id] = key
end

function SpatialIndex:Remove(id: string)
	local old = self.ItemCell[id]
	if not old then
		return
	end
	local bucket = self.Cells[old]
	if bucket then
		bucket[id] = nil
		if next(bucket) == nil then
			self.Cells[old] = nil
		end
	end
	self.ItemCell[id] = nil
	self.ItemPosition[id] = nil
	self.Items -= 1
end

function SpatialIndex:QueryRadius(position: Vector3, radius: number, out: { string }?): { string }
	local result = out or {}
	local cs = self.CellSize
	local minX = math.floor((position.X - radius) / cs)
	local maxX = math.floor((position.X + radius) / cs)
	local minZ = math.floor((position.Z - radius) / cs)
	local maxZ = math.floor((position.Z + radius) / cs)
	local r2 = radius * radius
	local cells = self.Cells
	local positions = self.ItemPosition
	-- For huge radii, iterating items is cheaper than iterating empty cells.
	if (maxX - minX + 1) * (maxZ - minZ + 1) > self.Items * 2 then
		for id, p in pairs(positions) do
			local dx, dz = p.X - position.X, p.Z - position.Z
			if dx * dx + dz * dz <= r2 then
				table.insert(result, id)
			end
		end
		return result
	end
	for cx = minX, maxX do
		for cz = minZ, maxZ do
			local bucket = cells[cellKey(cx, cz)]
			if bucket then
				for id in pairs(bucket) do
					local p = positions[id]
					local dx, dz = p.X - position.X, p.Z - position.Z
					if dx * dx + dz * dz <= r2 then
						table.insert(result, id)
					end
				end
			end
		end
	end
	return result
end

function SpatialIndex:Count(): number
	return self.Items
end

return SpatialIndex
