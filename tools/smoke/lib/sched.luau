--!nocheck
-- Virtual-time task scheduler for the smoke harness.
--
-- Game code never sees real time: os.clock(), tick(), task.wait() and
-- task.delay() all run on Sched.now, which only advances when a scenario
-- calls Sched.step(dt). That makes `while true do task.wait(1) end` loops
-- harmless and runs a 30-second fade in a few milliseconds.
--
-- Every game thread is a coroutine resumed through Sched.resume, so a Luau
-- error anywhere (a controller init, a signal handler, a delayed callback)
-- is captured with its message and traceback instead of killing the run.

local Sched = {}

Sched.now = 0
Sched.frame = 0
Sched.current = nil :: thread?
-- set by the harness: function(message: string, traceback: string, kind: string)
Sched.onError = nil :: ((string, string, string) -> ())?

type Sleeper = { co: thread, wake: number, start: number, seq: number, args: { any }?, n: number }

local sleeping: { Sleeper } = {}
local deferred: { { co: thread, args: { any }, n: number } } = {}
local seq = 0
local labels: { [thread]: string } = setmetatable({}, { __mode = "k" }) :: any

local function cleanError(err: any): (string, string)
	local text = tostring(err)
	-- mlua prefixes "runtime error: " and appends its own traceback
	text = string.gsub(text, "^runtime error: ", "")
	local msg, tb = string.match(text, "^(.-)\nstack traceback:\n(.*)$")
	if not msg then
		msg, tb = text, ""
	end
	return msg, tb
end
Sched.cleanError = cleanError

function Sched.label(co: thread, label: string)
	labels[co] = label
end

function Sched.resume(co: thread, ...: any)
	if coroutine.status(co) ~= "suspended" then
		return
	end
	local prev = Sched.current
	Sched.current = co
	local ok, err = coroutine.resume(co, ...)
	Sched.current = prev
	if not ok then
		local msg, tb = cleanError(err)
		local extra = debug.traceback(co)
		if tb == "" then
			tb = extra
		end
		if Sched.onError then
			Sched.onError(msg, tb, labels[co] or "thread")
		else
			print("[sched] unhandled error: " .. msg .. "\n" .. tb)
		end
	end
end

local function toThread(f: any): thread
	if type(f) == "thread" then
		return f
	elseif type(f) == "function" then
		return coroutine.create(f)
	end
	error("invalid argument #1 to 'spawn' (function or thread expected)", 3)
end

function Sched.spawn(f: any, ...: any): thread
	local co = toThread(f)
	Sched.resume(co, ...)
	return co
end

function Sched.defer(f: any, ...: any): thread
	local co = toThread(f)
	table.insert(deferred, { co = co, args = table.pack(...), n = select("#", ...) })
	return co
end

local function sleep(co: thread, seconds: number, args: { any }?, n: number?)
	seq += 1
	table.insert(sleeping, { co = co, wake = Sched.now + seconds, start = Sched.now, seq = seq, args = args, n = n or 0 })
end

function Sched.delay(seconds: number?, f: any, ...: any): thread
	local co = toThread(f)
	sleep(co, math.max(seconds or 0, 0), table.pack(...), select("#", ...))
	return co
end

function Sched.wait(seconds: number?): number
	local co = coroutine.running()
	if not coroutine.isyieldable() then
		error("task.wait called from a non-yieldable thread (harness main thread)", 2)
	end
	-- task.wait() and task.wait(0) resume on the next frame
	sleep(co, math.max(seconds or 0, 0), nil, 0)
	return coroutine.yield()
end

function Sched.cancel(co: thread)
	for i = #sleeping, 1, -1 do
		if sleeping[i].co == co then
			table.remove(sleeping, i)
		end
	end
	for i = #deferred, 1, -1 do
		if deferred[i].co == co then
			table.remove(deferred, i)
		end
	end
	if coroutine.status(co) == "suspended" then
		pcall(coroutine.close, co)
	end
end

function Sched.flushDeferred()
	local guard = 0
	while #deferred > 0 do
		guard += 1
		if guard > 20000 then
			if Sched.onError then
				Sched.onError("deferred queue did not drain (re-entrant task.defer loop?)", "", "scheduler")
			end
			table.clear(deferred)
			return
		end
		local d = table.remove(deferred, 1)
		Sched.resume(d.co, table.unpack(d.args, 1, d.n))
	end
end

-- Wake every sleeper due at or before Sched.now (after advancing it by dt).
function Sched.advance(dt: number)
	Sched.now += dt
	local due: { Sleeper } = {}
	for i = #sleeping, 1, -1 do
		local s = sleeping[i]
		if s.wake <= Sched.now + 1e-9 then
			table.insert(due, s)
			table.remove(sleeping, i)
		end
	end
	table.sort(due, function(a, b)
		if a.wake == b.wake then
			return a.seq < b.seq
		end
		return a.wake < b.wake
	end)
	for _, s in due do
		if s.args then
			Sched.resume(s.co, table.unpack(s.args, 1, s.n))
		else
			Sched.resume(s.co, Sched.now - s.start)
		end
		Sched.flushDeferred()
	end
end

function Sched.pending(): number
	return #sleeping + #deferred
end

-- Roblox-shaped task library bound to this scheduler.
function Sched.taskLib()
	return {
		spawn = Sched.spawn,
		defer = Sched.defer,
		delay = Sched.delay,
		wait = Sched.wait,
		cancel = Sched.cancel,
		synchronize = function() end,
		desynchronize = function() end,
	}
end

return Sched
