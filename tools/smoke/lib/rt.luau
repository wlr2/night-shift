--!nocheck
-- Fake Roblox runtime for the smoke harness: Instances, RBXScriptSignals,
-- Enum canonicalisation and the datatypes Lune lacks (TweenInfo, Random,
-- RaycastParams) or gets wrong (CFrame.lookAt).
--
-- Every game-visible Instance is a userdata proxy (typeof -> "Instance")
-- backed by a record that owns the hierarchy, attributes, tags and signals.
-- Each record also keeps a REAL @lune/roblox Instance of the same class (the
-- "shadow"): every property write is replayed on the shadow first, so an
-- unknown property, a wrong value type or a bad enum throws with Roblox's
-- rules, and unset properties read Roblox's defaults. Membership (property vs
-- event vs method, read-only, security) comes from the API dump index.

local roblox = require("@lune/roblox")
local Api = require("./api")
local Sched = require("./sched")

local Rt = {}

Rt.recs = {} :: { [any]: any }
Rt.layoutDirty = true
Rt.notes = {} :: { [string]: boolean } -- harness gaps, deduplicated
Rt.onNote = nil :: ((string) -> ())?
Rt.onWarn = nil :: ((string, string) -> ())?
Rt.onPrint = nil :: ((string, string) -> ())?
Rt.Getters = {} :: { [string]: { [string]: (any, string, any) -> any } }
Rt.Setters = {} :: { [string]: { [string]: (any, string, any, any, number) -> () } }
Rt.Methods = {} :: { [string]: { [string]: any } }
Rt.DefaultsByClass = {} :: { [string]: { [string]: any } } -- engine defaults Lune lacks or gets wrong
Rt.DefaultsByProp = {} :: { [string]: any }
local shadowDefaults: { [string]: { [string]: any } } = {}
Rt.dataModel = nil :: any

local recs = Rt.recs
local NIL = newproxy(false)
Rt.NIL = NIL
local nextId = 0

local V2, V3, CF, UD, UD2, C3 = roblox.Vector2, roblox.Vector3, roblox.CFrame, roblox.UDim, roblox.UDim2, roblox.Color3

function Rt.note(msg: string)
	if not Rt.notes[msg] then
		Rt.notes[msg] = true
		if Rt.onNote then
			Rt.onNote(msg)
		end
	end
end

-- First stack frame that belongs to the game source (src/...), for messages.
function Rt.callSite(): string
	for lvl = 2, 40 do
		local s, l = debug.info(lvl, "sl")
		if not s then
			break
		end
		if string.sub(s, 1, 4) == "src/" then
			return s .. ":" .. tostring(l)
		end
	end
	return "?"
end

-------------------------------------------------------------------------------
-- Enum canonicalisation (Lune hands out a fresh userdata per access, so the
-- same EnumItem would not work as a table key without this)

local enumCanon: { [string]: any } = {}
local enumTypeOf: { [any]: string } = {}
local enumTypes: { [string]: any } = {}

local function canonEnum(item: any): any
	local key = tostring(item)
	local c = enumCanon[key]
	if c == nil then
		enumCanon[key] = item
		return item
	end
	return c
end
Rt.canonEnum = canonEnum

local function enumType(name: string): any
	local w = enumTypes[name]
	if w then
		return w
	end
	local ok, real = pcall(function()
		return roblox.Enum[name]
	end)
	if not ok or real == nil then
		return nil
	end
	w = newproxy(true)
	local mt = getmetatable(w)
	local function items()
		local out = {}
		for _, it in real:GetEnumItems() do
			table.insert(out, canonEnum(it))
		end
		return out
	end
	mt.__index = function(_, k)
		if k == "GetEnumItems" then
			return function()
				return items()
			end
		elseif k == "FromName" then
			return function(_, n)
				local ok2, it = pcall(function()
					return real[n]
				end)
				return if ok2 and it ~= nil then canonEnum(it) else nil
			end
		elseif k == "FromValue" then
			return function(_, v)
				for _, it in items() do
					if it.Value == v then
						return it
					end
				end
				return nil
			end
		end
		local ok2, it = pcall(function()
			return real[k]
		end)
		if not ok2 or it == nil then
			error(tostring(k) .. ' is not a valid member of "Enum.' .. name .. '"', 2)
		end
		return canonEnum(it)
	end
	mt.__newindex = function()
		error("Enums are read-only", 2)
	end
	mt.__tostring = function()
		return name
	end
	enumTypeOf[w] = name
	enumTypes[name] = w
	return w
end
Rt.enumType = enumType

Rt.Enum = newproxy(true)
do
	local mt = getmetatable(Rt.Enum)
	mt.__index = function(_, k)
		if k == "GetEnums" then
			return function()
				local out = {}
				for _, e in roblox.Enum:GetEnums() do
					table.insert(out, enumType(tostring(e)))
				end
				return out
			end
		end
		local w = enumType(k)
		if not w then
			error(tostring(k) .. ' is not a valid member of "Enum"', 2)
		end
		return w
	end
	mt.__tostring = function()
		return "Enum"
	end
end

-- enum type name of a (Lune) EnumItem, e.g. "KeyCode"
local function enumItemType(item: any): string?
	local s = tostring(item)
	return string.match(s, "Enum%.([%w_]+)%.") or string.match(s, "^([%w_]+)%.")
end

-------------------------------------------------------------------------------
-- custom datatypes

local customType: { [any]: string } = setmetatable({}, { __mode = "k" }) :: any

local function readonlyRecord(typeName: string, fields: { [string]: any }, methods: { [string]: any }?): any
	local u = newproxy(true)
	local mt = getmetatable(u)
	mt.__index = function(_, k)
		local v = fields[k]
		if v ~= nil then
			return v
		end
		if methods and methods[k] then
			return methods[k]
		end
		error(tostring(k) .. " is not a valid member of " .. typeName, 2)
	end
	mt.__newindex = function(_, k, v)
		if methods and methods.__set then
			return methods.__set(fields, k, v)
		end
		error(tostring(k) .. " cannot be assigned to", 2)
	end
	mt.__tostring = function()
		return typeName
	end
	customType[u] = typeName
	return u
end
Rt.record = readonlyRecord

Rt.TweenInfo = {
	new = function(time, style, direction, repeatCount, reverses, delayTime)
		if time ~= nil and type(time) ~= "number" then
			error("invalid argument #1 to 'new' (number expected, got " .. Rt.typeof(time) .. ")", 2)
		end
		local E = Rt.Enum
		return readonlyRecord("TweenInfo", {
			Time = time or 1,
			EasingStyle = style or E.EasingStyle.Quad,
			EasingDirection = direction or E.EasingDirection.Out,
			RepeatCount = repeatCount or 0,
			Reverses = reverses or false,
			DelayTime = delayTime or 0,
		})
	end,
}

-- Small deterministic PRNG with Roblox's Random surface.
local function mul32(a: number, b: number): number
	local ah, al = bit32.rshift(a, 16), bit32.band(a, 0xFFFF)
	local bh, bl = bit32.rshift(b, 16), bit32.band(b, 0xFFFF)
	return bit32.band(al * bl + bit32.lshift(bit32.band(ah * bl + al * bh, 0xFFFF), 16), 0xFFFFFFFF)
end

local function newRandom(seed: number): any
	local state = { s = bit32.band(math.floor(math.abs(seed or 0)) % 4294967296, 0xFFFFFFFF) }
	local function next32(): number
		state.s = bit32.band(state.s + 0x6D2B79F5, 0xFFFFFFFF)
		local t = state.s
		t = mul32(bit32.bxor(t, bit32.rshift(t, 15)), bit32.bor(t, 1))
		t = bit32.bxor(t, t + mul32(bit32.bxor(t, bit32.rshift(t, 7)), bit32.bor(t, 61)))
		t = bit32.band(t, 0xFFFFFFFF)
		return bit32.bxor(t, bit32.rshift(t, 14))
	end
	local function unit(): number
		return next32() / 4294967296
	end
	local methods = {}
	methods.NextNumber = function(_, lo, hi)
		if lo == nil then
			return unit()
		end
		return lo + (hi - lo) * unit()
	end
	methods.NextInteger = function(_, lo, hi)
		if type(lo) ~= "number" or type(hi) ~= "number" then
			error("invalid argument to 'NextInteger' (number expected)", 2)
		end
		lo, hi = math.floor(lo), math.floor(hi)
		if hi < lo then
			error("invalid argument #2 to 'NextInteger' (interval is empty)", 2)
		end
		return lo + math.floor(unit() * (hi - lo + 1))
	end
	methods.NextUnitVector = function()
		local v = V3.new(unit() * 2 - 1, unit() * 2 - 1, unit() * 2 - 1)
		return if v.Magnitude > 0 then v.Unit else V3.new(1, 0, 0)
	end
	methods.Shuffle = function(_, t)
		for i = #t, 2, -1 do
			local j = 1 + math.floor(unit() * i)
			t[i], t[j] = t[j], t[i]
		end
	end
	methods.Clone = function()
		local c = newRandom(0)
		Rt.randomState(c).s = state.s
		return c
	end
	local u = readonlyRecord("Random", {}, methods)
	Rt._randStates = Rt._randStates or setmetatable({}, { __mode = "k" })
	Rt._randStates[u] = state
	return u
end
function Rt.randomState(u: any)
	return Rt._randStates[u]
end
Rt.Random = {
	new = function(seed: number?)
		return newRandom(seed or math.floor(os.clock() * 1000))
	end,
}

local function paramsCtor(typeName: string)
	return {
		new = function()
			local fields = {
				FilterType = Rt.Enum.RaycastFilterType.Exclude,
				FilterDescendantsInstances = {},
				IgnoreWater = false,
				CollisionGroup = "Default",
				RespectCanCollide = false,
				BruteForceAllSlow = false,
				MaxParts = 0,
			}
			return readonlyRecord(typeName, fields, {
				AddToFilter = function(_, x)
					table.insert(fields.FilterDescendantsInstances, x)
				end,
				__set = function(f, k, v)
					if f[k] == nil then
						error(tostring(k) .. " is not a valid member of " .. typeName, 3)
					end
					f[k] = v
				end,
			})
		end,
	}
end
Rt.RaycastParams = paramsCtor("RaycastParams")
Rt.OverlapParams = paramsCtor("OverlapParams")

-- Lune's CFrame.lookAt returns wrong rotations for some inputs and its
-- CFrame.new rejects the 2-argument (pos, lookAt) form; Roblox supports both.
local function lookAt(at: any, target: any, up: any?): any
	local upv = up or V3.new(0, 1, 0)
	local look = target - at
	if look.Magnitude < 1e-9 then
		return CF.new(at.X, at.Y, at.Z)
	end
	look = look.Unit
	local right = look:Cross(upv)
	if right.Magnitude < 1e-6 then
		right = look:Cross(V3.new(0, 0, 1))
		if right.Magnitude < 1e-6 then
			right = look:Cross(V3.new(1, 0, 0))
		end
	end
	right = right.Unit
	local up2 = right:Cross(look).Unit
	local back = -look
	return CF.new(at.X, at.Y, at.Z, right.X, up2.X, back.X, right.Y, up2.Y, back.Y, right.Z, up2.Z, back.Z)
end
Rt.lookAt = lookAt
Rt.CFrame = setmetatable({
	lookAt = lookAt,
	new = function(...)
		if select("#", ...) == 2 then
			local a, b = ...
			if typeof(a) == "Vector3" and typeof(b) == "Vector3" then
				return lookAt(a, b)
			end
		end
		return CF.new(...)
	end,
}, { __index = CF })

Rt.Content = setmetatable({
	fromObject = function(obj: any)
		local r = recs[obj]
		if r then
			local shadow = r.shadow
			if not shadow then
				local ok, s = pcall(roblox.Instance.new, "EditableImage")
				shadow = if ok then s else nil
			end
			if shadow then
				return roblox.Content.fromObject(shadow)
			end
			return roblox.Content.none
		end
		return roblox.Content.fromObject(obj)
	end,
}, { __index = roblox.Content })

-------------------------------------------------------------------------------
-- RBXScriptSignal / RBXScriptConnection

local sigRecs: { [any]: any } = {}
local connRecs: { [any]: any } = {}
Rt.sigRecs = sigRecs

local connMeta = {}
local function newConnection(sr: any, fn: any, once: boolean): any
	local u = newproxy(true)
	local c = { sig = sr, fn = fn, connected = true, once = once, proxy = u }
	connRecs[u] = c
	local mt = getmetatable(u)
	mt.__index = function(_, k)
		if k == "Connected" then
			return c.connected
		elseif k == "Disconnect" or k == "disconnect" then
			return function()
				if c.connected then
					c.connected = false
					local list = c.sig.conns
					for i, x in list do
						if x == c then
							table.remove(list, i)
							break
						end
					end
				end
			end
		end
		error(tostring(k) .. " is not a valid member of RBXScriptConnection", 2)
	end
	mt.__tostring = function()
		return "Connection"
	end
	return c
end
local _ = connMeta

function Rt.newSignal(name: string): (any, any)
	local u = newproxy(true)
	local sr = { name = name, conns = {}, waiting = {}, proxy = u }
	sigRecs[u] = sr
	local mt = getmetatable(u)
	local function connect(self, fn)
		if sigRecs[self] ~= sr then
			error("Expected ':' not '.' calling member function Connect", 2)
		end
		if type(fn) ~= "function" then
			error("Attempt to connect failed: Passed value is not a function", 2)
		end
		local c = newConnection(sr, fn, false)
		table.insert(sr.conns, c)
		return c.proxy
	end
	local methods = {
		Connect = connect,
		connect = connect,
		ConnectParallel = connect,
		Once = function(self, fn)
			local proxy = connect(self, fn)
			connRecs[proxy].once = true
			return proxy
		end,
		Wait = function(self)
			if not coroutine.isyieldable() then
				error("Signal:Wait() from a non-yieldable thread", 2)
			end
			table.insert(sr.waiting, coroutine.running())
			return coroutine.yield()
		end,
	}
	methods.wait = methods.Wait
	mt.__index = function(_, k)
		local m = methods[k]
		if m then
			return m
		end
		error(tostring(k) .. " is not a valid member of RBXScriptSignal", 2)
	end
	mt.__tostring = function()
		return "Signal " .. name
	end
	return u, sr
end

local function sigRec(s: any): any
	return sigRecs[s] or s
end

-- Engine-side fire: every handler starts now in its own thread (task.spawn
-- semantics), errors are captured by the scheduler.
function Rt.fire(s: any, ...: any)
	local sr = sigRec(s)
	if not sr or not sr.conns then
		return
	end
	if #sr.conns > 0 then
		for _, c in table.clone(sr.conns) do
			if c.connected then
				if c.once then
					c.connected = false
					local i = table.find(sr.conns, c)
					if i then
						table.remove(sr.conns, i)
					end
				end
				Sched.spawn(c.fn, ...)
			end
		end
	end
	if #sr.waiting > 0 then
		local w = sr.waiting
		sr.waiting = {}
		for _, co in w do
			Sched.resume(co, ...)
		end
	end
end

-- Deferred fire (Roblox's default SignalBehavior): handlers run at the next
-- resumption point, after the current thread yields or finishes.
function Rt.fireDeferred(s: any, ...: any)
	local sr = sigRec(s)
	if not sr or (#sr.conns == 0 and #sr.waiting == 0) then
		return
	end
	local args = table.pack(...)
	Sched.defer(function()
		Rt.fire(sr, table.unpack(args, 1, args.n))
	end)
end

function Rt.connectionCount(s: any): number
	local sr = sigRec(s)
	return if sr and sr.conns then #sr.conns else 0
end

function Rt.disconnectAll(s: any)
	local sr = sigRec(s)
	if not sr then
		return
	end
	for _, c in sr.conns do
		c.connected = false
	end
	table.clear(sr.conns)
end

-------------------------------------------------------------------------------
-- typeof

function Rt.typeof(v: any): string
	if type(v) == "userdata" then
		if recs[v] then
			return "Instance"
		elseif sigRecs[v] then
			return "RBXScriptSignal"
		elseif connRecs[v] then
			return "RBXScriptConnection"
		elseif enumTypeOf[v] then
			return "Enum"
		elseif v == Rt.Enum then
			return "Enums"
		end
		local c = customType[v]
		if c then
			return c
		end
	end
	return typeof(v)
end

-------------------------------------------------------------------------------
-- Instances

local impls: { [string]: any } = {}

local function classImpl(className: string): any
	local im = impls[className]
	if im then
		return im
	end
	im = { members = Api.members(className), getters = {}, setters = {}, methods = {} }
	local chain = Api.chain(className)
	if #chain == 0 then
		chain = { className }
	end
	for i = #chain, 1, -1 do
		local cname = chain[i]
		for k, f in Rt.Getters[cname] or {} do
			im.getters[k] = f
		end
		for k, f in Rt.Setters[cname] or {} do
			im.setters[k] = f
		end
		for k, f in Rt.Methods[cname] or {} do
			im.methods[k] = f
		end
	end
	impls[className] = im
	return im
end
Rt.classImpl = classImpl
function Rt.resetImpls()
	table.clear(impls)
end

function Rt.fullName(r: any): string
	local parts = {}
	local cur = r
	while cur do
		if cur.class == "DataModel" then
			break
		end
		table.insert(parts, 1, cur.name)
		cur = cur.parent and recs[cur.parent]
	end
	return table.concat(parts, ".")
end

local function memberError(r: any, key: any, level: number)
	error(string.format('%s is not a valid member of %s "%s"', tostring(key), r.class, Rt.fullName(r)), level + 1)
end

local stubs: { [string]: any } = {}
local function stubMethod(className: string, name: string): any
	local key = className .. ":" .. name
	local f = stubs[key]
	if f then
		return f
	end
	f = function(self, ...)
		Rt.note(string.format("unimplemented engine method %s called from %s (returned nil)", key, Rt.callSite()))
		return nil
	end
	stubs[key] = f
	return f
end

local function typeDefault(m: any): any
	local t, cat = m.type, m.cat
	if cat == "P" then
		if t == "bool" then
			return false
		elseif t == "string" or t == "BinaryString" or t == "ProtectedString" then
			return ""
		else
			return 0
		end
	elseif cat == "E" then
		local et = enumType(t)
		local items = et and et:GetEnumItems()
		return items and items[1]
	elseif cat == "D" then
		if t == "Vector2" then
			return V2.zero
		elseif t == "Vector3" then
			return V3.zero
		elseif t == "UDim2" then
			return UD2.new()
		elseif t == "UDim" then
			return UD.new()
		elseif t == "CFrame" then
			return CF.identity
		elseif t == "Color3" then
			return C3.new(1, 1, 1)
		elseif t == "Font" then
			return roblox.Font.fromEnum(roblox.Enum.Font.Legacy)
		elseif t == "Content" then
			return roblox.Content.none
		elseif t == "NumberRange" then
			return roblox.NumberRange.new(0)
		elseif t == "Rect" then
			return roblox.Rect.new(0, 0, 0, 0)
		end
	end
	return nil
end

function Rt.readProp(r: any, key: string, m: any): any
	local v = r.props[key]
	if v ~= nil then
		if v == NIL then
			return nil
		end
		return v
	end
	if m.cat == "C" then
		return nil
	end
	local dc = Rt.DefaultsByClass[r.class]
	local d = dc and dc[key]
	if d == nil then
		d = Rt.DefaultsByProp[key]
	end
	if d ~= nil then
		return d
	end
	local cache = shadowDefaults[r.class]
	if not cache then
		cache = {}
		shadowDefaults[r.class] = cache
	end
	local cached = cache[key]
	if cached ~= nil then
		if cached == NIL then
			return nil
		end
		return cached
	end
	local shadow = r.shadow
	local value = nil
	local ok = false
	if shadow then
		ok, value = pcall(function()
			return shadow[key]
		end)
		if ok and typeof(value) == "EnumItem" then
			value = canonEnum(value)
		end
	end
	if not ok then
		value = typeDefault(m)
		Rt.note(string.format("no default known for %s.%s; harness used %s", r.class, key, tostring(value)))
	end
	cache[key] = if value == nil then NIL else value
	return value
end

-- value coercions Roblox performs on property assignment (Lune does not)
local function coerce(r: any, key: string, m: any, value: any): (boolean, any)
	local cat, t = m.cat, m.type
	if cat == "P" then
		if t == "bool" then
			if type(value) ~= "boolean" then
				return false, "bool expected, got " .. Rt.typeof(value)
			end
		elseif t == "string" then
			if type(value) == "number" then
				return true, tostring(value)
			elseif type(value) ~= "string" then
				return false, "string expected, got " .. Rt.typeof(value)
			end
		elseif t == "int" or t == "int64" or t == "float" or t == "double" then
			if type(value) == "string" and tonumber(value) then
				return true, tonumber(value)
			elseif type(value) ~= "number" then
				return false, "number expected, got " .. Rt.typeof(value)
			end
			if t == "int" or t == "int64" then
				if value ~= value then
					return true, 0
				end
				return true, math.clamp(if value >= 0 then math.floor(value) else math.ceil(value), -2 ^ 31, 2 ^ 31 - 1)
			end
		end
	elseif cat == "E" then
		local et = enumType(t)
		if type(value) == "string" then
			local it = et and et:FromName(value)
			if not it then
				return false, string.format('Invalid value "%s" for enum %s', value, t)
			end
			return true, it
		elseif type(value) == "number" then
			local it = et and et:FromValue(value)
			if not it then
				return false, string.format("Invalid value %s for enum %s", tostring(value), t)
			end
			return true, it
		elseif typeof(value) == "EnumItem" then
			local vt = enumItemType(value)
			if vt ~= t then
				return false, string.format("EnumItem of type %s cannot be assigned to a property of type %s", tostring(vt), t)
			end
			return true, canonEnum(value)
		else
			return false, "EnumItem expected, got " .. Rt.typeof(value)
		end
	elseif cat == "C" then
		if value == nil then
			return true, nil
		end
		local vr = recs[value]
		if not vr then
			return false, "Object expected, got " .. Rt.typeof(value)
		end
		if not Api.isA(vr.class, t) then
			return false, string.format("%s expected, got %s", t, vr.class)
		end
		return true, value
	elseif cat == "D" then
		if t ~= "Content" and t ~= "ContentId" and typeof(value) ~= t and not (t == "Font" and typeof(value) == "Font") then
			-- let the shadow decide for convertible types (e.g. Content from string)
			if t == "Vector2" or t == "Vector3" or t == "UDim2" or t == "UDim" or t == "Color3" or t == "CFrame" or t == "Font" or t == "Rect" or t == "NumberRange" or t == "NumberSequence" or t == "ColorSequence" then
				return false, t .. " expected, got " .. Rt.typeof(value)
			end
		end
	end
	return true, value
end

local function firstLine(s: string): string
	s = string.gsub(tostring(s), "^%s+", "")
	return (string.match(s, "^[^\n]*") or s)
end

local GUI_LAYOUT_CLASSES = nil
local function isGuiRelated(r: any): boolean
	local c = r.class
	if GUI_LAYOUT_CLASSES == nil then
		GUI_LAYOUT_CLASSES = {}
	end
	local v = GUI_LAYOUT_CLASSES[c]
	if v == nil then
		v = Api.isA(c, "GuiBase2d") or Api.isA(c, "UIBase") or Api.isA(c, "UIComponent") or Api.isA(c, "UIConstraint") or c == "UIScale" or c == "UIPadding" or c == "UIStroke"
		GUI_LAYOUT_CLASSES[c] = v
	end
	return v
end

-- marks the ScreenGui containing r for re-layout
function Rt.markLayout(r: any)
	local cur = r
	local depth = 0
	while cur and depth < 64 do
		if cur.class == "ScreenGui" then
			cur.layoutDirty = true
			Rt.layoutDirty = true
			return
		end
		cur = cur.parent and recs[cur.parent]
		depth += 1
	end
end

function Rt.changed(r: any, key: string)
	if isGuiRelated(r) and key ~= "AbsoluteSize" and key ~= "AbsolutePosition" then
		Rt.markLayout(r)
	end
	local ps = r.propSignals and r.propSignals[key]
	if ps then
		Rt.fireDeferred(ps, nil)
	end
	local ch = r.signals.Changed
	if ch then
		Rt.fireDeferred(ch, key)
	end
end

local function valuesEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) == "number" and type(b) == "number" then
		return math.abs(a - b) < 1e-7
	end
	return false
end

-- Write without any checks (harness backdoor for read-only engine state).
function Rt.setInternal(p: any, key: string, value: any)
	local r = recs[p]
	local old = r.props[key]
	r.props[key] = if value == nil then NIL else value
	if not valuesEqual(old, r.props[key]) then
		Rt.changed(r, key)
	end
end

function Rt.writeProp(r: any, key: string, m: any, value: any, level: number)
	local ok, v = coerce(r, key, m, value)
	if not ok then
		error(string.format("Unable to assign property %s. %s", key, v), level + 1)
	end
	-- previous value first: the class-default cache must never see this write
	local old = r.props[key]
	if old == nil then
		old = Rt.readProp(r, key, m)
	elseif old == NIL then
		old = nil
	end
	local stored = v
	if m.cat ~= "C" and r.shadow then
		local shadow = r.shadow
		local okw, err = pcall(function()
			shadow[key] = v
		end)
		if not okw then
			local msg = firstLine(err)
			if string.find(msg, "not a valid member", 1, true) then
				-- Lune's own class database is older than the API dump: trust the dump
				Rt.note(string.format("Lune does not know %s.%s; value accepted unchecked", r.class, key))
			else
				error(string.format("Unable to assign property %s. %s", key, msg), level + 1)
			end
		else
			local okr, rb = pcall(function()
				return shadow[key]
			end)
			if okr and rb ~= nil then
				stored = if typeof(rb) == "EnumItem" then canonEnum(rb) else rb
			end
		end
	end
	r.props[key] = if stored == nil then NIL else stored
	if not valuesEqual(old, stored) then
		Rt.changed(r, key)
	end
end

local function getSignal(r: any, key: string): any
	local s = r.signals[key]
	if not s then
		s = Rt.newSignal(r.class .. "." .. key)
		r.signals[key] = s
	end
	return s
end
Rt.getSignal = function(p: any, key: string)
	return getSignal(recs[p], key)
end

function Rt.findChild(r: any, name: string): any
	for _, c in r.children do
		if recs[c].name == name then
			return c
		end
	end
	return nil
end

local function INDEX(p: any, key: any): any
	local r = recs[p]
	if key == "Name" then
		return r.name
	elseif key == "Parent" then
		return r.parent
	elseif key == "ClassName" then
		return r.class
	end
	local im = r.impl
	local m = im.members[key]
	if m ~= nil then
		local kind = m.kind
		if kind == "p" then
			local g = im.getters[key]
			if g then
				return g(r, key, m)
			end
			if bit32.band(m.flags, 2) ~= 0 then
				memberError(r, key, 2)
			end
			if bit32.band(m.flags, 16) ~= 0 then
				error(string.format("The current thread cannot read '%s' (lacking capability)", key), 2)
			end
			return Rt.readProp(r, key, m)
		elseif kind == "e" then
			return getSignal(r, key)
		elseif kind == "m" then
			return im.methods[key] or stubMethod(r.class, key)
		elseif kind == "c" then
			error(string.format("%s is a callback member of %s; you can only set the callback value, get is not available", key, r.class), 2)
		end
	end
	local g = im.getters[key]
	if g then
		return g(r, key, nil)
	end
	local meth = im.methods[key]
	if meth then
		return meth
	end
	if type(key) == "string" then
		local child = Rt.findChild(r, key)
		if child then
			return child
		end
	end
	memberError(r, key, 2)
	return nil
end

local function NEWINDEX(p: any, key: any, value: any)
	local r = recs[p]
	if key == "Parent" then
		Rt.setParent(r, value, 2)
		return
	elseif key == "Name" then
		if type(value) == "number" then
			value = tostring(value)
		end
		if type(value) ~= "string" then
			error("Unable to assign property Name. string expected, got " .. Rt.typeof(value), 2)
		end
		if r.name ~= value then
			r.name = value
			Rt.changed(r, "Name")
		end
		return
	end
	local im = r.impl
	local m = im.members[key]
	local setter = im.setters[key]
	if m == nil then
		if setter then
			setter(r, key, nil, value, 2)
			return
		end
		memberError(r, key, 2)
	end
	if m.kind == "c" then
		r.callbacks = r.callbacks or {}
		r.callbacks[key] = value
		return
	elseif m.kind ~= "p" then
		error(string.format("Unable to assign property %s. Property is read only", tostring(key)), 2)
	end
	if bit32.band(m.flags, 2) ~= 0 then
		memberError(r, key, 2)
	end
	if bit32.band(m.flags, 1) ~= 0 then
		error(string.format("Unable to assign property %s. Property is read only", key), 2)
	end
	if bit32.band(m.flags, 8) ~= 0 then
		error(string.format("The current thread cannot write '%s' (lacking capability)", key), 2)
	end
	if setter then
		setter(r, key, m, value, 2)
		return
	end
	Rt.writeProp(r, key, m, value, 2)
end

local function TOSTRING(p: any): string
	return recs[p].name
end

local function makeShadow(className: string): any
	local ok, s = pcall(roblox.Instance.new, className)
	if ok then
		return s
	end
	return nil
end

-- Internal constructor: no creatable check.
function Rt.newInstance(className: string, opts: { shadow: any?, name: string? }?): any
	local p = newproxy(true)
	local mt = getmetatable(p)
	mt.__index = INDEX
	mt.__newindex = NEWINDEX
	mt.__tostring = TOSTRING
	mt.__metatable = "The metatable is locked"
	nextId += 1
	local o = opts or {}
	local r = {
		proxy = p,
		class = className,
		name = o.name or className,
		parent = nil,
		children = {},
		shadow = if o.shadow ~= nil then o.shadow else makeShadow(className),
		props = {},
		attrs = {},
		tags = {},
		signals = {},
		propSignals = nil,
		attrSignals = nil,
		destroyed = false,
		locked = false,
		id = nextId,
		impl = classImpl(className),
	}
	recs[p] = r
	local init = Rt.Methods[className] and Rt.Methods[className].__init
	if init then
		init(r)
	end
	return p
end

-- Game-facing Instance.new
function Rt.createInstance(className: any, parent: any?): any
	if type(className) ~= "string" then
		error("invalid argument #1 to 'new' (string expected, got " .. Rt.typeof(className) .. ")", 2)
	end
	if not Api.exists(className) then
		error(string.format('Unable to create an Instance of type "%s"', className), 2)
	end
	if not Api.creatable(className) then
		error(string.format('Unable to create an Instance of type "%s"', className), 2)
	end
	local p = Rt.newInstance(className)
	if parent ~= nil then
		Rt.setParent(recs[p], parent, 2)
	end
	return p
end

function Rt.rec(p: any): any
	return recs[p]
end

function Rt.isInstance(v: any): boolean
	return recs[v] ~= nil
end

local function isAncestorRec(a: any, b: any): boolean
	-- is a an ancestor of b?
	local cur = b.parent and recs[b.parent]
	while cur do
		if cur == a then
			return true
		end
		cur = cur.parent and recs[cur.parent]
	end
	return false
end
Rt.isAncestorRec = isAncestorRec

function Rt.inDataModel(r: any): boolean
	local cur = r
	while cur do
		if cur.class == "DataModel" then
			return true
		end
		cur = cur.parent and recs[cur.parent]
	end
	return false
end

local function eachDescendant(r: any, fn: (any) -> ())
	for _, c in table.clone(r.children) do
		local cr = recs[c]
		fn(cr)
		eachDescendant(cr, fn)
	end
end
Rt.eachDescendant = eachDescendant

-- CollectionService hooks (set by services.luau)
Rt.onTaggedEnter = nil :: ((any) -> ())?
Rt.onTaggedLeave = nil :: ((any) -> ())?

function Rt.setParent(r: any, newParent: any, level: number)
	if r.locked then
		error(string.format("The Parent property of %s is locked, current parent: NULL, new parent %s", r.name, if newParent and recs[newParent] then recs[newParent].name else "NULL"), level + 1)
	end
	if newParent ~= nil and not recs[newParent] then
		error("Unable to assign property Parent. Object expected, got " .. Rt.typeof(newParent), level + 1)
	end
	if r.parent == newParent then
		return
	end
	local np = newParent and recs[newParent]
	if np and (np == r or isAncestorRec(r, np)) then
		error(string.format("Attempt to set parent of %s to %s would result in circular reference", Rt.fullName(r), Rt.fullName(np)), level + 1)
	end
	local wasIn = Rt.inDataModel(r)
	local old = r.parent and recs[r.parent]
	if old and isGuiRelated(r) then
		Rt.markLayout(old)
	end
	if old then
		local cur = old
		while cur do
			local s = cur.signals.DescendantRemoving
			if s then
				Rt.fire(s, r.proxy)
			end
			cur = cur.parent and recs[cur.parent]
		end
		local i = table.find(old.children, r.proxy)
		if i then
			table.remove(old.children, i)
		end
		if old.signals.ChildRemoved then
			Rt.fireDeferred(old.signals.ChildRemoved, r.proxy)
		end
	end
	r.parent = newParent
	if np then
		table.insert(np.children, r.proxy)
		if np.signals.ChildAdded then
			Rt.fireDeferred(np.signals.ChildAdded, r.proxy)
		end
		local cur = np
		while cur do
			local s = cur.signals.DescendantAdded
			if s then
				Rt.fireDeferred(s, r.proxy)
				eachDescendant(r, function(d)
					Rt.fireDeferred(s, d.proxy)
				end)
			end
			cur = cur.parent and recs[cur.parent]
		end
	end
	if r.signals.AncestryChanged then
		Rt.fireDeferred(r.signals.AncestryChanged, r.proxy, newParent)
	end
	eachDescendant(r, function(d)
		if d.signals.AncestryChanged then
			Rt.fireDeferred(d.signals.AncestryChanged, r.proxy, newParent)
		end
	end)
	local isIn = Rt.inDataModel(r)
	if isIn and not wasIn and Rt.onTaggedEnter then
		Rt.onTaggedEnter(r)
		eachDescendant(r, Rt.onTaggedEnter)
	elseif wasIn and not isIn and Rt.onTaggedLeave then
		Rt.onTaggedLeave(r)
		eachDescendant(r, Rt.onTaggedLeave)
	end
	Rt.changed(r, "Parent")
end

function Rt.destroy(r: any)
	if r.destroyed then
		return
	end
	if r.signals.Destroying then
		Rt.fire(r.signals.Destroying)
	end
	for _, c in table.clone(r.children) do
		Rt.destroy(recs[c])
	end
	r.locked = false
	Rt.setParent(r, nil, 1)
	r.locked = true
	r.destroyed = true
	for _, s in r.signals do
		Rt.disconnectAll(s)
	end
	if r.propSignals then
		for _, s in r.propSignals do
			Rt.disconnectAll(s)
		end
	end
	if r.attrSignals then
		for _, s in r.attrSignals do
			Rt.disconnectAll(s)
		end
	end
	if r.onDestroy then
		r.onDestroy(r)
	end
end

function Rt.clone(r: any): any
	if r.props.Archivable == false then
		return nil
	end
	local shadow = nil
	if r.shadow then
		local ok, s = pcall(function()
			return r.shadow:Clone()
		end)
		shadow = if ok then s else nil
	end
	local p = Rt.newInstance(r.class, { shadow = shadow or false, name = r.name })
	local c = recs[p]
	if not c.shadow then
		c.shadow = nil
	end
	for k, v in r.props do
		c.props[k] = v
	end
	for k, v in r.attrs do
		c.attrs[k] = v
	end
	for k, v in r.tags do
		c.tags[k] = v
	end
	for _, ch in r.children do
		local cc = Rt.clone(recs[ch])
		if cc then
			local ccr = recs[cc]
			ccr.parent = p
			table.insert(c.children, cc)
		end
	end
	return p
end

local function selfRec(self: any, method: string): any
	local r = recs[self]
	if not r then
		error(string.format("Expected ':' not '.' calling member function %s", method), 3)
	end
	return r
end
Rt.selfRec = selfRec

local function attrSignal(r: any, name: string): any
	r.attrSignals = r.attrSignals or {}
	local s = r.attrSignals[name]
	if not s then
		s = Rt.newSignal(r.class .. ".Attribute(" .. name .. ")")
		r.attrSignals[name] = s
	end
	return s
end

local ATTR_TYPES = {
	string = true, boolean = true, number = true, UDim = true, UDim2 = true, BrickColor = true, Color3 = true,
	Vector2 = true, Vector3 = true, CFrame = true, NumberSequence = true, ColorSequence = true, NumberRange = true,
	Rect = true, Font = true, EnumItem = true,
}

function Rt.setAttribute(r: any, name: any, value: any, level: number)
	if type(name) ~= "string" then
		error("invalid argument #1 to 'SetAttribute' (string expected, got " .. Rt.typeof(name) .. ")", level + 1)
	end
	if #name > 100 or not string.match(name, "^[%w_]+$") or string.sub(name, 1, 3) == "RBX" then
		error(string.format("Attribute name '%s' is invalid", name), level + 1)
	end
	if value ~= nil and not ATTR_TYPES[Rt.typeof(value)] then
		error(string.format("%s is not a supported attribute type", Rt.typeof(value)), level + 1)
	end
	local old = r.attrs[name]
	r.attrs[name] = value
	if old ~= value then
		if r.attrSignals and r.attrSignals[name] then
			Rt.fireDeferred(r.attrSignals[name])
		end
		if r.signals.AttributeChanged then
			Rt.fireDeferred(r.signals.AttributeChanged, name)
		end
	end
end

-- Generic Instance methods ----------------------------------------------------

local function descendants(r: any, out: { any })
	for _, c in r.children do
		table.insert(out, c)
		descendants(recs[c], out)
	end
	return out
end

local function findFirst(r: any, pred: (any) -> boolean, recursive: boolean?): any
	for _, c in r.children do
		local cr = recs[c]
		if pred(cr) then
			return c
		end
	end
	if recursive then
		for _, c in r.children do
			local f = findFirst(recs[c], pred, true)
			if f then
				return f
			end
		end
	end
	return nil
end
Rt.findFirst = findFirst

local function checkString(v: any, method: string, argn: number?)
	if type(v) ~= "string" then
		error(string.format("invalid argument #%d to '%s' (string expected, got %s)", argn or 1, method, Rt.typeof(v)), 3)
	end
end

Rt.yieldReports = {} :: { any }

Rt.Methods.Instance = {
	FindFirstChild = function(self, name, recursive)
		local r = selfRec(self, "FindFirstChild")
		checkString(name, "FindFirstChild")
		return findFirst(r, function(c)
			return c.name == name
		end, recursive)
	end,
	FindFirstChildOfClass = function(self, className)
		local r = selfRec(self, "FindFirstChildOfClass")
		checkString(className, "FindFirstChildOfClass")
		return findFirst(r, function(c)
			return c.class == className
		end, false)
	end,
	FindFirstChildWhichIsA = function(self, className, recursive)
		local r = selfRec(self, "FindFirstChildWhichIsA")
		checkString(className, "FindFirstChildWhichIsA")
		return findFirst(r, function(c)
			return Api.isA(c.class, className)
		end, recursive)
	end,
	FindFirstDescendant = function(self, name)
		local r = selfRec(self, "FindFirstDescendant")
		return findFirst(r, function(c)
			return c.name == name
		end, true)
	end,
	FindFirstAncestor = function(self, name)
		local r = selfRec(self, "FindFirstAncestor")
		local cur = r.parent and recs[r.parent]
		while cur do
			if cur.name == name then
				return cur.proxy
			end
			cur = cur.parent and recs[cur.parent]
		end
		return nil
	end,
	FindFirstAncestorOfClass = function(self, className)
		local r = selfRec(self, "FindFirstAncestorOfClass")
		local cur = r.parent and recs[r.parent]
		while cur do
			if cur.class == className then
				return cur.proxy
			end
			cur = cur.parent and recs[cur.parent]
		end
		return nil
	end,
	FindFirstAncestorWhichIsA = function(self, className)
		local r = selfRec(self, "FindFirstAncestorWhichIsA")
		local cur = r.parent and recs[r.parent]
		while cur do
			if Api.isA(cur.class, className) then
				return cur.proxy
			end
			cur = cur.parent and recs[cur.parent]
		end
		return nil
	end,
	GetChildren = function(self)
		return table.clone(selfRec(self, "GetChildren").children)
	end,
	GetDescendants = function(self)
		return descendants(selfRec(self, "GetDescendants"), {})
	end,
	IsDescendantOf = function(self, other)
		local r = selfRec(self, "IsDescendantOf")
		if other == nil then
			return r.parent == nil -- Roblox: IsDescendantOf(nil) is true for parent-less instances
		end
		local o = recs[other]
		if not o then
			error("invalid argument #1 to 'IsDescendantOf' (Instance expected, got " .. Rt.typeof(other) .. ")", 2)
		end
		return isAncestorRec(o, r)
	end,
	IsAncestorOf = function(self, other)
		local r = selfRec(self, "IsAncestorOf")
		local o = recs[other]
		if not o then
			return false
		end
		return isAncestorRec(r, o)
	end,
	GetFullName = function(self)
		return Rt.fullName(selfRec(self, "GetFullName"))
	end,
	Destroy = function(self)
		Rt.destroy(selfRec(self, "Destroy"))
	end,
	Remove = function(self)
		local r = selfRec(self, "Remove")
		Rt.setParent(r, nil, 2)
	end,
	ClearAllChildren = function(self)
		local r = selfRec(self, "ClearAllChildren")
		for _, c in table.clone(r.children) do
			Rt.destroy(recs[c])
		end
	end,
	Clone = function(self)
		return Rt.clone(selfRec(self, "Clone"))
	end,
	WaitForChild = function(self, name, timeout)
		local r = selfRec(self, "WaitForChild")
		checkString(name, "WaitForChild")
		local found = Rt.findChild(r, name)
		if found then
			return found
		end
		if not coroutine.isyieldable() then
			error("WaitForChild would yield on the harness main thread: " .. Rt.fullName(r) .. ":WaitForChild(\"" .. name .. "\")", 2)
		end
		local co = coroutine.running()
		local site = Rt.callSite()
		local done = false
		local conn
		local function finish(v)
			if done then
				return
			end
			done = true
			if conn then
				conn.Disconnect()
			end
			for i, y in Rt.yieldReports do
				if y.co == co then
					table.remove(Rt.yieldReports, i)
					break
				end
			end
			Sched.resume(co, v)
		end
		local sig = getSignal(r, "ChildAdded")
		local c = newConnection(sigRecs[sig], function(child)
			if recs[child] and recs[child].name == name then
				finish(child)
			end
		end, false)
		table.insert(sigRecs[sig].conns, c)
		conn = { Disconnect = function()
			c.connected = false
			local i = table.find(sigRecs[sig].conns, c)
			if i then
				table.remove(sigRecs[sig].conns, i)
			end
		end }
		if timeout ~= nil then
			Sched.delay(timeout, function()
				finish(nil)
			end)
		else
			Sched.delay(5, function()
				if not done then
					table.insert(Rt.yieldReports, { co = co, what = string.format('%s:WaitForChild("%s")', Rt.fullName(r), name), site = site, t = Sched.now })
					if Rt.onWarn then
						Rt.onWarn(string.format('Infinite yield possible on \'%s:WaitForChild("%s")\'', Rt.fullName(r), name), site)
					end
				end
			end)
		end
		return coroutine.yield()
	end,
	GetAttribute = function(self, name)
		local r = selfRec(self, "GetAttribute")
		checkString(name, "GetAttribute")
		return r.attrs[name]
	end,
	SetAttribute = function(self, name, value)
		Rt.setAttribute(selfRec(self, "SetAttribute"), name, value, 2)
	end,
	GetAttributes = function(self)
		return table.clone(selfRec(self, "GetAttributes").attrs)
	end,
	GetAttributeChangedSignal = function(self, name)
		local r = selfRec(self, "GetAttributeChangedSignal")
		checkString(name, "GetAttributeChangedSignal")
		return attrSignal(r, name)
	end,
	AddTag = function(self, tag)
		local r = selfRec(self, "AddTag")
		checkString(tag, "AddTag")
		if not r.tags[tag] then
			r.tags[tag] = true
			if Rt.onTagAdded then
				Rt.onTagAdded(r, tag)
			end
		end
	end,
	RemoveTag = function(self, tag)
		local r = selfRec(self, "RemoveTag")
		if r.tags[tag] then
			r.tags[tag] = nil
			if Rt.onTagRemoved then
				Rt.onTagRemoved(r, tag)
			end
		end
	end,
	HasTag = function(self, tag)
		return selfRec(self, "HasTag").tags[tag] == true
	end,
	GetTags = function(self)
		local out = {}
		for t in selfRec(self, "GetTags").tags do
			table.insert(out, t)
		end
		return out
	end,
	GetDebugId = function(self)
		return tostring(selfRec(self, "GetDebugId").id)
	end,
	GetActor = function()
		return nil
	end,
	IsPropertyModified = function(self, prop)
		return selfRec(self, "IsPropertyModified").props[prop] ~= nil
	end,
	ResetPropertyToDefault = function(self, prop)
		local r = selfRec(self, "ResetPropertyToDefault")
		r.props[prop] = nil
		Rt.changed(r, prop)
	end,
}
local I = Rt.Methods.Instance
I.children = I.GetChildren
I.clone = I.Clone
I.destroy = I.Destroy
I.remove = I.Remove
I.findFirstChild = I.FindFirstChild
I.getChildren = I.GetChildren
I.isDescendantOf = I.IsDescendantOf

Rt.Methods.Object = {
	IsA = function(self, className)
		local r = selfRec(self, "IsA")
		if type(className) ~= "string" then
			error("invalid argument #1 to 'IsA' (string expected, got " .. Rt.typeof(className) .. ")", 2)
		end
		return Api.isA(r.class, className)
	end,
	GetPropertyChangedSignal = function(self, prop)
		local r = selfRec(self, "GetPropertyChangedSignal")
		if type(prop) ~= "string" then
			error("invalid argument #1 to 'GetPropertyChangedSignal' (string expected)", 2)
		end
		local m = r.impl.members[prop]
		if not m or m.kind ~= "p" then
			error(string.format("%s is not a valid property name.", prop), 2)
		end
		r.propSignals = r.propSignals or {}
		local s = r.propSignals[prop]
		if not s then
			s = Rt.newSignal(r.class .. ".Changed(" .. prop .. ")")
			r.propSignals[prop] = s
		end
		return s
	end,
}
Rt.Methods.Object.isA = Rt.Methods.Object.IsA

return Rt
