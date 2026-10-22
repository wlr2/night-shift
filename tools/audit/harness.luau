--!nocheck
-- Headless layout harness (Lune, not part of the Rojo place). Type checking is
-- off because luau-lsp's Roblox definitions do not describe the @lune/* modules.
--
-- Runs the REAL src/server/Systems/MapBuilder.luau outside Studio and dumps
-- the built map as JSON for tools/audit/analyze.py. The source tree is mounted
-- as ModuleScripts under ReplicatedStorage / ServerScriptService exactly like
-- default.project.json, so `require(ReplicatedStorage.Shared.Layout)` and
-- `script.Parent` resolve to the repo files. Services and engine APIs Lune
-- does not implement are mocked around MapBuilder; MapBuilder itself is never
-- modified.
--
-- Usage: lune run tools/audit/harness.luau <src dir> <out.json>
--
-- Instances are wrapped in thin proxies so that engine-derived properties
-- (BasePart.Position / Orientation, Model pivots) behave like Roblox. Without
-- them Lune would silently store a Position that never moves the part.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local RealInstance = roblox.Instance
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3
local Enum = roblox.Enum

local function fail(_msg: string)
	process.exit(2)
end

local srcArg = process.args[1]
local outArg = process.args[2]
if not srcArg or not outArg then
	print("usage: lune run tools/audit/harness.luau <src dir> <out.json>")
	process.exit(64)
end

local SRC = srcArg
if fs.isDir(SRC .. "/src/server") then
	SRC = SRC .. "/src"
end
if not fs.isFile(SRC .. "/server/Systems/MapBuilder.luau") then
	print("[audit harness] no server/Systems/MapBuilder.luau under " .. SRC)
	process.exit(66)
end

local warnings: { string } = {}
local notes: { string } = {}

local function joinArgs(...: any): string
	local parts = {}
	for i = 1, select("#", ...) do
		table.insert(parts, tostring((select(i, ...))))
	end
	return table.concat(parts, " ")
end

-------------------------------------------------------------------------------
-- Instance proxies
-------------------------------------------------------------------------------

local REAL = {} -- private key: proxy[REAL] = real Lune instance
local ProxyMT = {}
local proxies: { [string]: any } = {}

local function isProxy(v: any): boolean
	return type(v) == "table" and getmetatable(v) == ProxyMT
end

local function unwrap(v: any): any
	if isProxy(v) then
		return rawget(v, REAL)
	end
	return v
end

local function wrap(v: any): any
	if typeof(v) ~= "Instance" then
		return v
	end
	local id = v:GetDebugId()
	local p = proxies[id]
	if p == nil then
		p = setmetatable({ [REAL] = v }, ProxyMT)
		proxies[id] = p
	end
	return p
end

local function unwrapArgs(...: any): ...any
	local n = select("#", ...)
	local t = table.pack(...)
	for i = 1, n do
		local v = t[i]
		if isProxy(v) then
			t[i] = rawget(v, REAL)
		elseif type(v) == "table" and getmetatable(v) == nil then
			-- arrays of instances (e.g. FilterDescendantsInstances)
			local copy = nil
			for k, x in v do
				if isProxy(x) then
					copy = copy or table.clone(v)
					copy[k] = rawget(x, REAL)
				end
			end
			if copy then
				t[i] = copy
			end
		end
	end
	return table.unpack(t, 1, n)
end

local function wrapResults(...: any): ...any
	local n = select("#", ...)
	local t = table.pack(...)
	for i = 1, n do
		local v = t[i]
		if typeof(v) == "Instance" then
			t[i] = wrap(v)
		elseif type(v) == "table" and getmetatable(v) == nil and typeof(v[1]) == "Instance" then
			local out = table.create(#v)
			for k, x in v do
				out[k] = wrap(x)
			end
			t[i] = out
		end
	end
	return table.unpack(t, 1, n)
end

-- mock RBXScriptSignal: connections are accepted and never fired
local function newSignal(name: string?): any
	local sig = { _name = name or "Signal" }
	function sig:Connect(_fn)
		return { Connected = true, Disconnect = function(c)
			c.Connected = false
		end }
	end
	sig.Once = sig.Connect
	sig.ConnectParallel = sig.Connect
	function sig:Wait()
		error("[audit harness] " .. self._name .. ":Wait() would yield forever in a headless build", 2)
	end
	return sig
end

local EVENTS: { [string]: boolean } = {}
for _, e in
	{
		"Changed", "ChildAdded", "ChildRemoved", "DescendantAdded", "DescendantRemoving", "AncestryChanged",
		"Destroying", "AttributeChanged", "Touched", "TouchEnded", "Triggered", "TriggerEnded", "PromptShown",
		"PromptHidden", "PromptButtonHoldBegan", "PromptButtonHoldEnded", "MouseClick", "RightMouseClick",
		"MouseHoverEnter", "MouseHoverLeave", "Activated", "MouseButton1Click", "MouseButton1Down", "MouseEnter",
		"MouseLeave", "Completed", "Died", "Seated", "StateChanged", "Running", "OnServerEvent", "OnClientEvent",
		"Event", "OnServerInvoke", "OnInvoke", "Ended", "Played", "Loaded", "DidLoop",
	}
do
	EVENTS[e] = true
end

local function pivotOf(real: any): any
	if real:IsA("BasePart") then
		return real.CFrame
	elseif real:IsA("Model") then
		local pp = real.PrimaryPart
		if pp then
			return pp.CFrame
		end
		local stored = real:GetAttribute("__auditPivot")
		if typeof(stored) == "CFrame" then
			return stored
		end
		local lo, hi = nil, nil
		for _, d in real:GetDescendants() do
			if d:IsA("BasePart") then
				local p = d.CFrame.Position
				lo = if lo then lo:Min(p) else p
				hi = if hi then hi:Max(p) else p
			end
		end
		return if lo then CFrame.new((lo + hi) / 2) else CFrame.identity
	elseif real:IsA("Attachment") then
		local parent = real.Parent
		return if parent and parent:IsA("BasePart") then parent.CFrame * real.CFrame else real.CFrame
	end
	error("[audit harness] GetPivot on " .. real.ClassName .. " is not mocked", 3)
end

local function boundsOf(real: any): (any, any)
	local lo, hi = nil, nil
	local list = real:GetDescendants()
	if real:IsA("BasePart") then
		table.insert(list, real)
	end
	for _, d in list do
		if d:IsA("BasePart") then
			local cf, s = d.CFrame, d.Size / 2
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local p = cf:PointToWorldSpace(Vector3.new(s.X * sx, s.Y * sy, s.Z * sz))
						lo = if lo then lo:Min(p) else p
						hi = if hi then hi:Max(p) else p
					end
				end
			end
		end
	end
	if not lo then
		return CFrame.identity, Vector3.zero
	end
	return CFrame.new((lo + hi) / 2), hi - lo
end

-- engine-derived members Lune lacks; all receive the REAL instance
local GET: { [string]: (any) -> any } = {
	Position = function(r)
		if r:IsA("BasePart") then
			return r.CFrame.Position
		end
		return r.Position
	end,
	Orientation = function(r)
		if r:IsA("BasePart") then
			local x, y, z = r.CFrame:ToOrientation()
			return Vector3.new(math.deg(x), math.deg(y), math.deg(z))
		end
		return r.Orientation
	end,
	Rotation = function(r)
		if r:IsA("BasePart") then
			return r.CFrame.Rotation
		end
		return r.Rotation
	end,
	WorldCFrame = function(r)
		return pivotOf(r)
	end,
	WorldPosition = function(r)
		return pivotOf(r).Position
	end,
	AssemblyLinearVelocity = function()
		return Vector3.zero
	end,
	AssemblyAngularVelocity = function()
		return Vector3.zero
	end,
}

local SET: { [string]: (any, any) -> boolean } = {
	Position = function(r, v)
		if r:IsA("BasePart") then
			r.CFrame = CFrame.new(v) * r.CFrame.Rotation
			return true
		end
		return false
	end,
	Orientation = function(r, v)
		if r:IsA("BasePart") then
			r.CFrame = CFrame.new(r.CFrame.Position) * CFrame.fromOrientation(math.rad(v.X), math.rad(v.Y), math.rad(v.Z))
			return true
		end
		return false
	end,
}

local METHODS: { [string]: (any, ...any) -> ...any } = {
	GetPivot = function(r)
		return pivotOf(r)
	end,
	PivotTo = function(r, cf)
		if r:IsA("BasePart") then
			r.CFrame = cf
			return
		end
		local delta = cf * pivotOf(r):Inverse()
		for _, d in r:GetDescendants() do
			if d:IsA("BasePart") then
				d.CFrame = delta * d.CFrame
			end
		end
		if r:IsA("Model") and not r.PrimaryPart then
			r:SetAttribute("__auditPivot", cf)
		end
	end,
	GetBoundingBox = function(r)
		return boundsOf(r)
	end,
	GetExtentsSize = function(r)
		local _, size = boundsOf(r)
		return size
	end,
	WaitForChild = function(r, name)
		local c = r:FindFirstChild(name)
		if not c then
			error("[audit harness] " .. r:GetFullName() .. ":WaitForChild('" .. tostring(name) .. "') would yield forever", 3)
		end
		return c
	end,
	Clone = function(r)
		return r:Clone()
	end,
	GetPropertyChangedSignal = function(_r, prop)
		return newSignal("GetPropertyChangedSignal(" .. tostring(prop) .. ")")
	end,
	GetAttributeChangedSignal = function(_r, attr)
		return newSignal("GetAttributeChangedSignal(" .. tostring(attr) .. ")")
	end,
	Sit = function() end,
	SetNetworkOwner = function() end,
	SetNetworkOwnershipAuto = function() end,
	ApplyImpulse = function() end,
	BreakJoints = function() end,
	MakeJoints = function() end,
	ScaleTo = function(r, s)
		if not r:IsA("Model") then
			error("[audit harness] ScaleTo is only mocked for Models", 3)
		end
		local pivot = pivotOf(r)
		for _, d in r:GetDescendants() do
			if d:IsA("BasePart") then
				local rel = pivot:ToObjectSpace(d.CFrame)
				d.Size *= s
				d.CFrame = pivot * (rel - rel.Position + rel.Position * s)
			end
		end
	end,
}

ProxyMT.__index = function(self, key)
	local real = rawget(self, REAL)
	local m = METHODS[key]
	if m then
		return function(selfArg, ...)
			return wrapResults(m(unwrap(selfArg), unwrapArgs(...)))
		end
	end
	local g = GET[key]
	if g then
		return wrapResults(g(real))
	end
	local ok, v = pcall(function()
		return real[key]
	end)
	if not ok then
		if EVENTS[key] then
			return newSignal(key)
		end
		error(string.format("[audit harness] %s.%s: %s", real:GetFullName(), tostring(key), tostring(v)), 2)
	end
	if type(v) == "function" then
		return function(selfArg, ...)
			return wrapResults(v(unwrap(selfArg), unwrapArgs(...)))
		end
	end
	return wrapResults(v)
end

ProxyMT.__newindex = function(self, key, value)
	local real = rawget(self, REAL)
	local s = SET[key]
	if s and s(real, unwrap(value)) then
		return
	end
	local ok, err = pcall(function()
		real[key] = unwrap(value)
	end)
	if not ok then
		error(string.format("[audit harness] cannot set %s.%s: %s", real:GetFullName(), tostring(key), tostring(err)), 2)
	end
end

ProxyMT.__tostring = function(self)
	return tostring(rawget(self, REAL).Name)
end

-------------------------------------------------------------------------------
-- DataModel, source tree and services
-------------------------------------------------------------------------------

local realGame = RealInstance.new("DataModel")
local realWorkspace = realGame:GetService("Workspace")
local realLighting = realGame:GetService("Lighting")

local modulePaths: { [string]: string } = {} -- debug id -> file path

-- Mirrors Rojo's directory rules for the subset this repo uses.
local function mount(dir: string, name: string, parent: any)
	local inst
	local initFile = nil
	for _, candidate in { { "init.luau", "ModuleScript" }, { "init.lua", "ModuleScript" }, { "init.server.luau", "Script" }, { "init.client.luau", "LocalScript" } } do
		if fs.isFile(dir .. "/" .. candidate[1]) then
			inst = RealInstance.new(candidate[2])
			initFile = dir .. "/" .. candidate[1]
			break
		end
	end
	inst = inst or RealInstance.new("Folder")
	inst.Name = name
	if initFile then
		modulePaths[inst:GetDebugId()] = initFile
	end
	local entries = fs.readDir(dir)
	table.sort(entries)
	for _, entry in entries do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			mount(path, entry, inst)
		elseif not string.match(entry, "^init%.") then
			local base, ext = string.match(entry, "^(.-)%.(server%.luau)$")
			local class = "Script"
			if not base then
				base, ext = string.match(entry, "^(.-)%.(client%.luau)$")
				class = "LocalScript"
			end
			if not base then
				base, ext = string.match(entry, "^(.-)%.(luau?)$")
				class = "ModuleScript"
			end
			if base and ext then
				local m = RealInstance.new(class)
				m.Name = base
				m.Parent = inst
				modulePaths[m:GetDebugId()] = path
			end
		end
	end
	inst.Parent = parent
	return inst
end

local realReplicated = realGame:GetService("ReplicatedStorage")
local realServerScripts = realGame:GetService("ServerScriptService")
mount(SRC .. "/shared", "Shared", realReplicated)
mount(SRC .. "/art", "ArtData", realReplicated)
mount(SRC .. "/server", "Server", realServerScripts)

-- CollectionService: tags live on the real instances
local CollectionService = {}
function CollectionService:AddTag(inst, tag)
	unwrap(inst):AddTag(tag)
end
function CollectionService:RemoveTag(inst, tag)
	unwrap(inst):RemoveTag(tag)
end
function CollectionService:HasTag(inst, tag)
	return unwrap(inst):HasTag(tag)
end
function CollectionService:GetTags(inst)
	return unwrap(inst):GetTags()
end
function CollectionService:GetTagged(tag)
	local out = {}
	for _, d in realGame:GetDescendants() do
		if d:HasTag(tag) then
			table.insert(out, wrap(d))
		end
	end
	return out
end
function CollectionService:GetInstanceAddedSignal(tag)
	return newSignal("GetInstanceAddedSignal(" .. tostring(tag) .. ")")
end
function CollectionService:GetInstanceRemovedSignal(tag)
	return newSignal("GetInstanceRemovedSignal(" .. tostring(tag) .. ")")
end

local collisionGroups: { [string]: boolean } = { Default = true }
local collidable: { [string]: boolean } = {}
local PhysicsService = {}
function PhysicsService:RegisterCollisionGroup(name)
	collisionGroups[name] = true
end
PhysicsService.CreateCollisionGroup = PhysicsService.RegisterCollisionGroup
function PhysicsService:IsCollisionGroupRegistered(name)
	return collisionGroups[name] == true
end
function PhysicsService:UnregisterCollisionGroup(name)
	collisionGroups[name] = nil
end
function PhysicsService:CollisionGroupSetCollidable(a, b, v)
	collidable[a .. "|" .. b] = v
	collidable[b .. "|" .. a] = v
end
function PhysicsService:CollisionGroupsAreCollidable(a, b)
	local v = collidable[a .. "|" .. b]
	return v == nil or v
end
function PhysicsService:GetRegisteredCollisionGroups()
	local out = {}
	for name in collisionGroups do
		table.insert(out, { name = name, mask = 0 })
	end
	return out
end
function PhysicsService:GetMaxCollisionGroups()
	return 32
end

local Players = {
	LocalPlayer = nil,
	MaxPlayers = 4,
	CharacterAutoLoads = true,
	PlayerAdded = newSignal("PlayerAdded"),
	PlayerRemoving = newSignal("PlayerRemoving"),
}
function Players:GetPlayers()
	return {}
end
function Players:GetPlayerFromCharacter()
	return nil
end
function Players:GetPlayerByUserId()
	return nil
end

local RunService = {
	Heartbeat = newSignal("Heartbeat"),
	Stepped = newSignal("Stepped"),
	RenderStepped = newSignal("RenderStepped"),
	PreSimulation = newSignal("PreSimulation"),
	PostSimulation = newSignal("PostSimulation"),
	PreRender = newSignal("PreRender"),
}
function RunService:IsServer()
	return true
end
function RunService:IsClient()
	return false
end
function RunService:IsStudio()
	return false
end
function RunService:IsRunning()
	return true
end
function RunService:IsRunMode()
	return false
end
function RunService:BindToRenderStep() end
function RunService:UnbindFromRenderStep() end

-- tweens jump straight to their goal: the audit sees the final layout
local TweenService = {}
function TweenService:Create(inst, info, goals)
	local tween = { Instance = inst, TweenInfo = info, PlaybackState = Enum.PlaybackState.Begin, Completed = newSignal("Completed") }
	function tween:Play()
		for k, v in goals do
			inst[k] = v
		end
		self.PlaybackState = Enum.PlaybackState.Completed
	end
	function tween:Cancel() end
	function tween:Pause() end
	function tween:Destroy() end
	return tween
end
function TweenService:GetValue(alpha)
	return alpha
end

local guid = 0
local HttpService = {}
function HttpService:GenerateGUID(braces)
	guid += 1
	local s = string.format("00000000-0000-4000-8000-%012d", guid)
	return if braces == false then s else "{" .. s .. "}"
end
function HttpService:JSONEncode(v)
	return serde.encode("json", v)
end
function HttpService:JSONDecode(s)
	return serde.decode("json", s)
end

local Debris = {}
function Debris:AddItem() end

local mockServices: { [string]: any } = {
	CollectionService = CollectionService,
	PhysicsService = PhysicsService,
	Players = Players,
	RunService = RunService,
	TweenService = TweenService,
	HttpService = HttpService,
	Debris = Debris,
}

local function getService(name: string): any
	local m = mockServices[name]
	if m then
		return m
	end
	local ok, svc = pcall(function()
		return realGame:GetService(name)
	end)
	if not ok then
		error("[audit harness] game:GetService('" .. tostring(name) .. "') is not available headlessly: " .. tostring(svc), 3)
	end
	return wrap(svc)
end

local game = wrap(realGame)
-- GetService results can be plain mock tables, so `game` gets its own proxy
local gameMethods = {
	GetService = function(_self, name)
		return getService(name)
	end,
	FindService = function(_self, name)
		return getService(name)
	end,
}
gameMethods.service = gameMethods.GetService
local gameProxy = setmetatable({}, {
	__index = function(_, key)
		local m = gameMethods[key]
		if m then
			return m
		end
		local v = game[key]
		if type(v) == "function" then
			return function(_self, ...)
				return v(game, ...)
			end
		end
		return v
	end,
	__newindex = function(_, key, value)
		game[key] = value
	end,
	__tostring = function()
		return "Game"
	end,
})

-------------------------------------------------------------------------------
-- Globals and require
-------------------------------------------------------------------------------

local InstanceLib = {}
function InstanceLib.new(className: string, parent: any?)
	local ok, inst = pcall(RealInstance.new, className)
	if not ok then
		error("[audit harness] Instance.new('" .. tostring(className) .. "'): " .. tostring(inst), 2)
	end
	if parent ~= nil then
		inst.Parent = unwrap(parent)
	end
	return wrap(inst)
end
function InstanceLib.fromExisting(other)
	return wrap(unwrap(other):Clone())
end

local function auditTypeof(v: any): string
	if isProxy(v) then
		return "Instance"
	end
	return typeof(v)
end

local RandomLib = {}
function RandomLib.new(seed: number?)
	local state = math.floor(math.abs(seed or 1)) % 2147483646 + 1
	local r = {}
	local function nextUnit(): number
		state = (state * 48271) % 2147483647
		return (state - 1) / 2147483646
	end
	function r:NextNumber(lo, hi)
		lo, hi = lo or 0, hi or 1
		return lo + (hi - lo) * nextUnit()
	end
	function r:NextInteger(lo, hi)
		return lo + math.floor(nextUnit() * (hi - lo + 1))
	end
	function r:NextUnitVector()
		local v = Vector3.new(nextUnit() - 0.5, nextUnit() - 0.5, nextUnit() - 0.5)
		return if v.Magnitude > 1e-6 then v.Unit else Vector3.xAxis
	end
	function r:Shuffle(t)
		for i = #t, 2, -1 do
			local j = self:NextInteger(1, i)
			t[i], t[j] = t[j], t[i]
		end
	end
	function r:Clone()
		return RandomLib.new(state)
	end
	return r
end

local TweenInfoLib = {}
function TweenInfoLib.new(time, style, direction, repeatCount, reverses, delay)
	return { Time = time or 1, EasingStyle = style, EasingDirection = direction, RepeatCount = repeatCount or 0, Reverses = reverses or false, DelayTime = delay or 0 }
end

local function paramsLib()
	return {
		new = function()
			return { FilterDescendantsInstances = {}, FilterType = Enum.RaycastFilterType.Exclude, IgnoreWater = false, CollisionGroup = "Default", RespectCanCollide = false, MaxParts = 0 }
		end,
	}
end

local clock = 0
local DateTimeLib = {}
function DateTimeLib.now()
	return { UnixTimestamp = 0, UnixTimestampMillis = 0 }
end

-- task: spawn runs inline like Roblox; deferred and delayed work runs after
-- init returns (bounded), so delayed placement still lands in the dump
local deferred: { { fn: any, args: any, at: number } } = {}
local function runThread(fn, ...)
	local co = if type(fn) == "thread" then fn else coroutine.create(fn)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		error(debug.traceback(co, tostring(err)), 0)
	end
	return co
end
local taskLib = {}
function taskLib.spawn(fn, ...)
	return runThread(fn, ...)
end
function taskLib.defer(fn, ...)
	table.insert(deferred, { fn = fn, args = table.pack(...), at = clock })
	return nil
end
function taskLib.delay(t, fn, ...)
	table.insert(deferred, { fn = fn, args = table.pack(...), at = clock + (t or 0) })
	return nil
end
function taskLib.wait(t)
	clock += t or 0.03
	return t or 0.03
end
function taskLib.cancel() end
function taskLib.synchronize() end
function taskLib.desynchronize() end

local moduleCache: { [string]: any } = {}
local loading: { [string]: boolean } = {}
local requireModule

local function makeEnv(scriptProxy: any): any
	return {
		game = gameProxy,
		Game = gameProxy,
		workspace = wrap(realWorkspace),
		Workspace = wrap(realWorkspace),
		script = scriptProxy,
		require = function(target)
			return requireModule(target)
		end,
		Instance = InstanceLib,
		typeof = auditTypeof,
		warn = function(...)
			local msg = joinArgs(...)
			table.insert(warnings, msg)
			print("[warn] " .. msg)
		end,
		print = function(...)
			print("[print] " .. joinArgs(...))
		end,
		task = taskLib,
		wait = taskLib.wait,
		delay = taskLib.delay,
		spawn = taskLib.spawn,
		tick = function()
			return clock
		end,
		time = function()
			return clock
		end,
		elapsedTime = function()
			return clock
		end,
		settings = function()
			error("[audit harness] settings() is not available headlessly", 2)
		end,
		shared = {},
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		Vector3int16 = roblox.Vector3int16,
		Vector2int16 = roblox.Vector2int16,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		BrickColor = roblox.BrickColor,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		Rect = roblox.Rect,
		Ray = roblox.Ray,
		Region3 = roblox.Region3,
		Region3int16 = roblox.Region3int16,
		NumberRange = roblox.NumberRange,
		NumberSequence = roblox.NumberSequence,
		NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
		ColorSequence = roblox.ColorSequence,
		ColorSequenceKeypoint = roblox.ColorSequenceKeypoint,
		PhysicalProperties = roblox.PhysicalProperties,
		Faces = roblox.Faces,
		Axes = roblox.Axes,
		Font = roblox.Font,
		Content = roblox.Content,
		Enum = roblox.Enum,
		Random = RandomLib,
		TweenInfo = TweenInfoLib,
		DateTime = DateTimeLib,
		RaycastParams = paramsLib(),
		OverlapParams = paramsLib(),
	}
end

local function rel(path: string): string
	local i = string.find(path, SRC, 1, true)
	if i == 1 then
		return "src" .. string.sub(path, #SRC + 1)
	end
	return path
end

requireModule = function(target: any): any
	local real = unwrap(target)
	if typeof(real) ~= "Instance" then
		error("[audit harness] require() of a " .. typeof(target) .. " is not supported (only ModuleScripts from the source tree)", 3)
	end
	local path = modulePaths[real:GetDebugId()]
	if not path then
		error("[audit harness] require(" .. real:GetFullName() .. "): not a ModuleScript from the mounted source tree", 3)
	end
	local cached = moduleCache[path]
	if cached ~= nil then
		return cached
	end
	if loading[path] then
		error("[audit harness] cyclic require of " .. rel(path), 3)
	end
	loading[path] = true
	local source = fs.readFile(path)
	local ok, chunk = pcall(luau.load, source, { debugName = rel(path), environment = makeEnv(wrap(real)) })
	if not ok then
		error("[audit harness] failed to compile " .. rel(path) .. ": " .. tostring(chunk), 3)
	end
	local result = chunk()
	loading[path] = nil
	if result == nil then
		error("[audit harness] module " .. rel(path) .. " returned nothing", 3)
	end
	moduleCache[path] = result
	return result
end

-------------------------------------------------------------------------------
-- Build
-------------------------------------------------------------------------------

local function findModule(path: { string }): any
	local cur = realGame
	for _, name in path do
		cur = cur:FindFirstChild(name)
		if not cur then
			error("[audit harness] missing " .. table.concat(path, "."))
		end
	end
	return wrap(cur)
end

local MapBuilder
local okBuild, buildErr = xpcall(function()
	MapBuilder = requireModule(findModule({ "ServerScriptService", "Server", "Systems", "MapBuilder" }))
	MapBuilder.init()
	-- flush deferred / delayed work in time order (bounded)
	local steps = 0
	while #deferred > 0 and steps < 2000 do
		table.sort(deferred, function(a, b)
			return a.at < b.at
		end)
		local job = table.remove(deferred, 1)
		clock = math.max(clock, job.at)
		runThread(job.fn, table.unpack(job.args, 1, job.args.n))
		steps += 1
	end
	if #deferred > 0 then
		table.insert(notes, "stopped flushing deferred tasks after 2000 steps")
	end
end, function(err)
	return debug.traceback(tostring(err), 2)
end)

if not okBuild then
	print("[audit harness] MapBuilder failed to build headlessly:\n" .. tostring(buildErr))
	local msg = tostring(buildErr)
	if string.find(msg, "not a valid member", 1, true) or string.find(msg, "headlessly", 1, true) or string.find(msg, "not mocked", 1, true) then
		print("[audit harness] If this is a Roblox API the harness does not mock yet, add it in tools/audit/harness.luau (METHODS/GET/SET or mockServices).")
	end
	fail("build failed")
end

-------------------------------------------------------------------------------
-- Dump
-------------------------------------------------------------------------------

local function v3(v: any): { number }
	return { v.X, v.Y, v.Z }
end

local function rgb(c: any): { number }
	return { math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5) }
end

local function cfRot(cf: any): { number }
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	return { r00, r01, r02, r10, r11, r12, r20, r21, r22 }
end

-- generic Luau value -> JSON-safe value
local function ser(v: any, depth: number?): any
	local d = depth or 0
	if d > 8 then
		return "<deep>"
	end
	local t = typeof(v)
	if isProxy(v) then
		local real = unwrap(v)
		local out = { ["$inst"] = real:GetDebugId(), class = real.ClassName, name = real.Name }
		if real:IsA("BasePart") then
			out.pos = v3(real.CFrame.Position)
		end
		return out
	elseif t == "Instance" then
		return { ["$inst"] = v:GetDebugId(), class = v.ClassName, name = v.Name }
	elseif t == "Vector3" then
		return v3(v)
	elseif t == "CFrame" then
		return { ["$cframe"] = true, pos = v3(v.Position), rot = cfRot(v) }
	elseif t == "Color3" then
		return rgb(v)
	elseif t == "EnumItem" then
		return tostring(v)
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			return tostring(v)
		end
		return v
	elseif t == "string" or t == "boolean" then
		return v
	elseif t == "table" then
		local n = #v
		local isArray = n > 0
		if isArray then
			for k in v do
				if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then
					isArray = false
					break
				end
			end
		end
		local out = {}
		if isArray then
			for i = 1, n do
				local s = ser(v[i], d + 1)
				out[i] = if s == nil then false else s
			end
		else
			for k, x in v do
				if type(k) == "string" or type(k) == "number" then
					local s = ser(x, d + 1)
					if s ~= nil then
						out[tostring(k)] = s
					end
				end
			end
		end
		return out
	end
	return nil
end

local function attrsOf(inst: any): { [string]: any }
	local out = {}
	for k, v in inst:GetAttributes() do
		if string.sub(k, 1, 7) ~= "__audit" then
			out[k] = ser(v)
		end
	end
	return out
end

local mapRoot = realWorkspace:FindFirstChild("Map")
if not mapRoot then
	print("[audit harness] MapBuilder.init() did not create workspace.Map")
	fail("no map")
end

local function topGroup(inst: any): string
	local cur = inst
	while cur and cur.Parent and cur.Parent ~= mapRoot and cur.Parent ~= realWorkspace do
		cur = cur.Parent
	end
	if cur and cur.Parent == mapRoot and cur ~= inst then
		return cur.Name
	elseif cur and cur.Parent == mapRoot then
		return "Map"
	end
	return "Workspace"
end

local function relPath(inst: any): string
	local names = {}
	local cur = inst
	while cur and cur ~= mapRoot and cur ~= realWorkspace do
		table.insert(names, 1, cur.Name)
		cur = cur.Parent
	end
	return table.concat(names, "/")
end

local parts = {}
local lights = {}
local prompts = {}
local classCounts: { [string]: number } = {}

local function hasPosition(inst: any): boolean
	-- a raw Position stored on the real instance means MapBuilder bypassed the proxy
	local ok = pcall(function()
		return inst.Position
	end)
	return ok
end

for _, inst in realWorkspace:GetDescendants() do
	classCounts[inst.ClassName] = (classCounts[inst.ClassName] or 0) + 1
	if inst:IsA("BasePart") then
		local cf = inst.CFrame
		local rec: { [string]: any } = {
			uid = inst:GetDebugId(),
			name = inst.Name,
			class = inst.ClassName,
			path = relPath(inst),
			group = topGroup(inst),
			parent = if inst.Parent then inst.Parent.Name else nil,
			size = v3(inst.Size),
			pos = v3(cf.Position),
			rot = cfRot(cf),
			collide = inst.CanCollide,
			query = inst.CanQuery,
			transparency = inst.Transparency,
			material = inst.Material.Name,
			color = rgb(inst.Color),
			collisionGroup = inst.CollisionGroup,
			attrs = attrsOf(inst),
			tags = inst:GetTags(),
		}
		if inst:IsA("Part") then
			rec.shape = inst.Shape.Name
		end
		local surfaces, textures, labels = {}, {}, {}
		for _, c in inst:GetChildren() do
			if c:IsA("Texture") then
				local s = c:GetAttribute("Surface")
				local name = if type(s) == "string" then s else "texture"
				if not table.find(surfaces, name) then
					table.insert(surfaces, name)
				end
				table.insert(textures, { surface = name, face = c.Face.Name, tileU = c.StudsPerTileU, tileV = c.StudsPerTileV })
			elseif c:IsA("SurfaceGui") then
				for _, t in c:GetDescendants() do
					if t:IsA("TextLabel") then
						table.insert(labels, t.Text)
					end
				end
			end
		end
		if #surfaces > 0 then
			rec.surfaces = surfaces
			rec.textures = textures
		end
		if #labels > 0 then
			rec.labels = labels
		end
		if inst:IsA("Seat") then
			rec.seat = true
		end
		if hasPosition(inst) then
			table.insert(warnings, "raw Position stored on " .. relPath(inst) .. " (set on an unwrapped instance?)")
		end
		table.insert(parts, rec)
	elseif inst:IsA("Light") then
		local holder = inst.Parent
		local pos = if holder and holder:IsA("BasePart") then holder.CFrame.Position else Vector3.zero
		local rec: { [string]: any } = {
			uid = inst:GetDebugId(),
			class = inst.ClassName,
			holder = if holder then holder:GetDebugId() else nil,
			holderName = if holder then holder.Name else nil,
			path = relPath(inst),
			group = topGroup(inst),
			pos = v3(pos),
			color = rgb(inst.Color),
			range = inst.Range,
			brightness = inst.Brightness,
			shadows = inst.Shadows,
			enabled = inst.Enabled,
		}
		if inst:IsA("SurfaceLight") or inst:IsA("SpotLight") then
			rec.face = inst.Face.Name
			rec.angle = inst.Angle
		end
		table.insert(lights, rec)
	elseif inst:IsA("ProximityPrompt") then
		table.insert(prompts, {
			holder = if inst.Parent then inst.Parent:GetDebugId() else nil,
			action = inst.ActionText,
			object = inst.ObjectText,
			distance = inst.MaxActivationDistance,
			key = inst.KeyboardKeyCode.Name,
		})
	end
end

-- light group membership from MapBuilder.refs
local refs = MapBuilder.refs or {}
local lightGroups: { [string]: { string } } = {}
local function addLightGroup(light: any, name: string)
	local real = unwrap(light)
	if typeof(real) ~= "Instance" then
		return
	end
	local id = real:GetDebugId()
	local list = lightGroups[id] or {}
	lightGroups[id] = list
	if not table.find(list, name) then
		table.insert(list, name)
	end
end
if type(refs.lights) == "table" then
	for name, list in refs.lights do
		for _, l in list do
			addLightGroup(l, tostring(name))
		end
	end
end
for _, spec in { { "emergencyLights", "emergency" }, { "deskLamps", "deskLamp" } } do
	local list = refs[spec[1]]
	if type(list) == "table" then
		for _, l in list do
			addLightGroup(l, spec[2])
		end
	end
end
if refs.workstationLamp then
	addLightGroup(refs.workstationLamp, "workstationLamp")
end
for _, rec in lights do
	rec.groups = lightGroups[rec.uid] or {}
end

local function moduleValue(path: { string }): any
	local ok, v = pcall(function()
		return requireModule(findModule(path))
	end)
	return if ok then v else nil
end

local Index = moduleValue({ "ReplicatedStorage", "ArtData", "Index" })
local models = {}
if Index and Index.models then
	for key, info in Index.models do
		models[key] = { min = v3(info.min), max = v3(info.max), tris = info.tris }
	end
end

local Layout = moduleValue({ "ReplicatedStorage", "Shared", "Layout" })
local Config = moduleValue({ "ReplicatedStorage", "Shared", "Config" })

-- Lighting is configured by default.project.json and client controllers, not
-- by MapBuilder; only report what the build itself put there.
local lightingChildren = {}
for _, c in realLighting:GetChildren() do
	table.insert(lightingChildren, c.ClassName .. ":" .. c.Name)
end

local dump = {
	version = 1,
	src = SRC,
	parts = parts,
	lights = lights,
	prompts = prompts,
	refs = ser(refs),
	layout = ser(Layout),
	reach = if Config and Config.REACH then ser(Config.REACH) else {},
	models = models,
	surfaces = if Index and Index.surfaces then ser(Index.surfaces) else {},
	lightingChildren = lightingChildren,
	classCounts = classCounts,
	collisionGroups = (function()
		local out = {}
		for k in collisionGroups do
			table.insert(out, k)
		end
		table.sort(out)
		return out
	end)(),
	warnings = warnings,
	notes = notes,
}

fs.writeFile(outArg, serde.encode("json", dump, false))
local anchors = 0
for _, p in parts do
	if p.attrs.ArtKey then
		anchors += 1
	end
end
print(string.format("[audit harness] %s: %d parts (%d art anchors), %d lights, %d warnings -> %s", rel(SRC .. "/server/Systems/MapBuilder.luau"), #parts, anchors, #lights, #warnings, outArg))
