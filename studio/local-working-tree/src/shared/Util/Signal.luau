--!strict
-- Tiny synchronous signal for cross-system events (no _G, no BindableEvents).

export type Connection = { Disconnect: (self: Connection) -> (), connected: boolean }

export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	_handlers: { { fn: (T...) -> (), conn: Connection } },
}

local Signal = {}

function Signal.new<T...>(): Signal<T...>
	local self = {} :: Signal<T...>
	self._handlers = {}
	self.Connect = function(s: Signal<T...>, fn: (T...) -> ()): Connection
		local conn: Connection
		conn = {
			connected = true,
			Disconnect = function(c: Connection)
				c.connected = false
				for i, h in s._handlers do
					if h.conn == c then
						table.remove(s._handlers, i)
						break
					end
				end
			end,
		}
		table.insert(s._handlers, { fn = fn, conn = conn })
		return conn
	end
	self.Fire = function(s: Signal<T...>, ...: T...)
		local list = table.clone(s._handlers)
		for _, h in list do
			if h.conn.connected then
				local ok, err = pcall(h.fn :: any, ...)
				if not ok then
					warn("[Signal] handler error:", err)
				end
			end
		end
	end
	return self
end

return Signal
