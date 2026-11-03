--!strict
--[[
	SharedUtilities
	Small dependency-free helpers shared by server and client:
	  * Signal        - lightweight synchronous event with safe handler errors
	  * ConnectionBag - owns RBXScriptConnections / Signal connections and counts
	                    live connections globally (diagnostics, lifecycle tests)
	  * TokenBucket   - rate limiting
	  * formatting and numeric helpers
]]

local SharedUtilities = {}

--------------------------------------------------------------------------------
-- Global live-connection accounting (Test L: no lingering event connections)
--------------------------------------------------------------------------------
local liveConnections = 0

function SharedUtilities.GetLiveConnectionCount(): number
	return liveConnections
end

--------------------------------------------------------------------------------
-- Signal
--------------------------------------------------------------------------------
export type SignalConnection = {
	Connected: boolean,
	Disconnect: (self: SignalConnection) -> (),
}

local Signal = {}
Signal.__index = Signal

export type Signal = typeof(setmetatable(
	{} :: { _handlers: { { fn: (...any) -> (), conn: SignalConnection } }, _name: string },
	Signal
))

function Signal.new(name: string?): Signal
	return setmetatable({ _handlers = {}, _name = name or "Signal" }, Signal)
end

function Signal.Connect(self: Signal, fn: (...any) -> ()): SignalConnection
	local handlers = self._handlers
	local conn = { Connected = true } :: any
	local entry = { fn = fn, conn = conn }
	function conn.Disconnect(c)
		if not c.Connected then
			return
		end
		c.Connected = false
		for i, e in ipairs(handlers) do
			if e == entry then
				table.remove(handlers, i)
				break
			end
		end
	end
	table.insert(handlers, entry)
	return conn
end

function Signal.Once(self: Signal, fn: (...any) -> ()): SignalConnection
	local conn: SignalConnection
	conn = self:Connect(function(...)
		conn:Disconnect()
		fn(...)
	end)
	return conn
end

function Signal.Fire(self: Signal, ...: any)
	local handlers = self._handlers
	if #handlers == 0 then
		return
	end
	-- Snapshot so handlers may disconnect themselves during dispatch.
	local snapshot = table.clone(handlers)
	for _, entry in ipairs(snapshot) do
		if entry.conn.Connected then
			local ok, err = pcall(entry.fn, ...)
			if not ok then
				warn(string.format("[EW] %s handler error: %s", self._name, tostring(err)))
			end
		end
	end
end

function Signal.HandlerCount(self: Signal): number
	return #self._handlers
end

function Signal.DisconnectAll(self: Signal)
	for _, entry in ipairs(self._handlers) do
		entry.conn.Connected = false
	end
	table.clear(self._handlers)
end

SharedUtilities.Signal = Signal

--------------------------------------------------------------------------------
-- ConnectionBag
--------------------------------------------------------------------------------
local ConnectionBag = {}
ConnectionBag.__index = ConnectionBag

export type ConnectionBag = typeof(setmetatable({} :: { _items: { any } }, ConnectionBag))

function ConnectionBag.new(): ConnectionBag
	return setmetatable({ _items = {} }, ConnectionBag)
end

function ConnectionBag.Add(self: ConnectionBag, connection: any): any
	table.insert(self._items, connection)
	liveConnections += 1
	return connection
end

function ConnectionBag.Count(self: ConnectionBag): number
	return #self._items
end

function ConnectionBag.Clean(self: ConnectionBag)
	local items = self._items
	for i = #items, 1, -1 do
		local item = items[i]
		local t = typeof(item)
		if t == "RBXScriptConnection" then
			item:Disconnect()
		elseif t == "table" and item.Disconnect then
			item:Disconnect()
		elseif t == "function" then
			item()
		end
		items[i] = nil
		liveConnections -= 1
	end
end

SharedUtilities.ConnectionBag = ConnectionBag

--------------------------------------------------------------------------------
-- TokenBucket
--------------------------------------------------------------------------------
local TokenBucket = {}
TokenBucket.__index = TokenBucket

export type TokenBucket = typeof(setmetatable({} :: { Capacity: number, Refill: number, Tokens: number, Last: number }, TokenBucket))

function TokenBucket.new(capacity: number, refillPerSecond: number): TokenBucket
	return setmetatable({ Capacity = capacity, Refill = refillPerSecond, Tokens = capacity, Last = os.clock() }, TokenBucket)
end

function TokenBucket.TryTake(self: TokenBucket, amount: number?): boolean
	local now = os.clock()
	self.Tokens = math.min(self.Capacity, self.Tokens + (now - self.Last) * self.Refill)
	self.Last = now
	local need = amount or 1
	if self.Tokens >= need then
		self.Tokens -= need
		return true
	end
	return false
end

SharedUtilities.TokenBucket = TokenBucket

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
function SharedUtilities.Round(x: number, decimals: number?): number
	local m = 10 ^ (decimals or 0)
	return math.floor(x * m + 0.5) / m
end

function SharedUtilities.FormatDb(x: number?): string
	if x == nil then
		return "--"
	elseif x == math.huge then
		return "inf"
	elseif x == -math.huge then
		return "-inf"
	end
	return string.format("%.1f", x)
end

function SharedUtilities.Quantize(x: number, step: number): number
	return math.floor(x / step + 0.5)
end

function SharedUtilities.ShortId(prefix: string, n: number): string
	return string.format("%s-%05d", prefix, n)
end

-- Walk up from an instance to find the first ancestor (inclusive) satisfying predicate.
function SharedUtilities.FindAncestor(instance: Instance?, predicate: (Instance) -> boolean, maxDepth: number?): Instance?
	local node = instance
	local depth = 0
	local limit = maxDepth or 32
	while node and depth < limit do
		if predicate(node) then
			return node
		end
		node = node.Parent
		depth += 1
	end
	return nil
end

return SharedUtilities
