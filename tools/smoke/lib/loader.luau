--!nocheck
-- Mounts the Rojo project (default.project.json) into the fake DataModel as
-- ModuleScript / LocalScript / Script / Folder instances and implements
-- `require` over them, so the game's modules load from the repo unmodified
-- with Roblox-like globals (game, workspace, script, Instance, Enum, task...).

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local Rt = require("./rt")
local Sched = require("./sched")
local World = require("./services")

local Loader = {}
Loader.root = "."
Loader.loaded = {} :: { [any]: any }
Loader.loading = {} :: { [any]: boolean }
Loader.failed = {} :: { [any]: string }
Loader.requireCount = 0

local recs = Rt.recs

local function exists(path: string): boolean
	return fs.isFile(path) or fs.isDir(path)
end

local function stem(file: string): (string, string)
	-- returns name, class
	local base = string.match(file, "([^/]+)$")
	local name, kind = string.match(base, "^(.-)%.(server)%.luau?$")
	if name then
		return name, "Script"
	end
	name, kind = string.match(base, "^(.-)%.(client)%.luau?$")
	if name then
		return name, "LocalScript"
	end
	name = string.match(base, "^(.-)%.luau?$")
	if name then
		return name, "ModuleScript"
	end
	return base, "Folder"
end

local function mountPath(path: string, name: string, parent: any)
	local full = Loader.root .. "/" .. path
	if fs.isFile(full) then
		local _, class = stem(path)
		if string.match(path, "%.json$") then
			class = "ModuleScript"
		end
		local inst = Rt.newInstance(class, { name = name })
		recs[inst].source = path
		-- read now: Lune's fs is async and cannot be called from game threads
		recs[inst].sourceText = fs.readFile(full)
		inst.Parent = parent
		return inst
	end
	if not fs.isDir(full) then
		error("project path missing: " .. path)
	end
	local class = "Folder"
	local initPath = nil
	for _, cand in { { "init.luau", "ModuleScript" }, { "init.lua", "ModuleScript" }, { "init.client.luau", "LocalScript" }, { "init.server.luau", "Script" }, { "init.client.lua", "LocalScript" }, { "init.server.lua", "Script" } } do
		if fs.isFile(full .. "/" .. cand[1]) then
			class = cand[2]
			initPath = path .. "/" .. cand[1]
			break
		end
	end
	local inst = Rt.newInstance(class, { name = name })
	if initPath then
		recs[inst].source = initPath
		recs[inst].sourceText = fs.readFile(Loader.root .. "/" .. initPath)
	end
	local entries = fs.readDir(full)
	table.sort(entries)
	for _, e in entries do
		if string.match(e, "^init%.") or string.sub(e, 1, 1) == "." then
			continue
		end
		local childPath = path .. "/" .. e
		local childFull = Loader.root .. "/" .. childPath
		if fs.isDir(childFull) then
			mountPath(childPath, e, inst)
		elseif string.match(e, "%.luau?$") then
			local n = stem(e)
			mountPath(childPath, n, inst)
		elseif string.match(e, "%.json$") and not string.match(e, "%.meta%.json$") then
			mountPath(childPath, (string.gsub(e, "%.json$", "")), inst)
		end
	end
	inst.Parent = parent
	return inst
end

local function mountNode(node: { [string]: any }, name: string, parent: any)
	local inst
	if node["$path"] then
		inst = mountPath(node["$path"], name, parent)
	else
		inst = parent:FindFirstChild(name)
		if not inst then
			inst = Rt.newInstance(node["$className"] or "Folder", { name = name })
			inst.Parent = parent
		end
	end
	for k, v in node do
		if string.sub(k, 1, 1) ~= "$" and type(v) == "table" then
			mountNode(v, k, inst)
		end
	end
	return inst
end

-- Mounts every tree node; services map to World.services, properties are
-- applied the way Rojo would.
function Loader.mount(projectFile: string)
	local project = serde.decode("json", fs.readFile(Loader.root .. "/" .. projectFile))
	Loader.project = project
	for svcName, node in project.tree do
		if string.sub(svcName, 1, 1) == "$" or type(node) ~= "table" then
			continue
		end
		local svc = World.services[svcName] or World.addService(svcName)
		for k, v in node do
			if string.sub(k, 1, 1) ~= "$" and type(v) == "table" then
				if svcName == "StarterPlayer" and k == "StarterPlayerScripts" then
					-- scripts are cloned into the player's PlayerScripts at join
					for kk, vv in v do
						if string.sub(kk, 1, 1) ~= "$" and type(vv) == "table" then
							mountNode(vv, kk, svc:FindFirstChild("StarterPlayerScripts"))
							mountNode(vv, kk, World.player:FindFirstChild("PlayerScripts"))
						end
					end
				else
					mountNode(v, k, svc)
				end
			end
		end
		local props = node["$properties"]
		if props then
			Loader.applyProps(svc, props)
		end
	end
end

function Loader.applyProps(inst: any, props: { [string]: any })
	local C3 = roblox.Color3
	for k, v in props do
		-- Rojo applies these at build time, so script write restrictions do not apply
		local ok, err = pcall(function()
			local r = recs[inst]
			local m = r.impl.members[k]
			if not m or m.kind ~= "p" then
				error("unknown property")
			end
			local value = v
			if m.cat == "D" and m.type == "Color3" and type(v) == "table" then
				value = C3.new(v[1], v[2], v[3])
			elseif m.cat == "E" and type(v) == "string" then
				value = Rt.enumType(m.type)[v]
			end
			Rt.setInternal(inst, k, value)
		end)
		if not ok then
			Rt.note(string.format("project property %s.%s not applied: %s", tostring(inst), k, tostring(err)))
		end
	end
end

-------------------------------------------------------------------------------
-- globals

local G = {}
Loader.globals = G

local function captureArgs(...: any): string
	local parts = {}
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		table.insert(parts, tostring(v))
	end
	return table.concat(parts, " ")
end

function Loader.makeGlobals()
	local base = getfenv(0)
	for _, k in {
		"assert", "error", "getmetatable", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget", "rawlen", "rawset",
		"select", "setmetatable", "tonumber", "tostring", "type", "unpack", "xpcall", "newproxy", "gcinfo",
		"math", "string", "table", "coroutine", "bit32", "utf8", "buffer", "getfenv", "setfenv",
	} do
		G[k] = base[k]
	end
	G.collectgarbage = function(opt)
		if opt == "count" then
			return gcinfo()
		end
		error("collectgarbage must be called with 'count'", 2)
	end
	G.debug = setmetatable({
		profilebegin = function() end,
		profileend = function() end,
		setmemorycategory = function() end,
		resetmemorycategory = function() end,
		dumpcodesize = function() end,
	}, { __index = base.debug })
	G.typeof = Rt.typeof
	G.print = function(...)
		if Rt.onPrint then
			Rt.onPrint(captureArgs(...), Rt.callSite())
		end
	end
	G.warn = function(...)
		if Rt.onWarn then
			Rt.onWarn(captureArgs(...), Rt.callSite())
		end
	end
	G.game = World.game
	G.Game = World.game
	G.workspace = World.workspace
	G.Workspace = World.workspace
	G.Instance = {
		new = Rt.createInstance,
		fromExisting = function(inst)
			return Rt.clone(recs[inst])
		end,
	}
	G.Enum = Rt.Enum
	G.task = Sched.taskLib()
	G.wait = function(t)
		local e = Sched.wait(t or 0.03)
		return e, Sched.now
	end
	G.delay = function(t, f)
		Sched.delay(t, f)
	end
	G.spawn = function(f)
		Sched.defer(f)
	end
	G.Delay, G.Spawn, G.Wait = G.delay, G.spawn, G.wait
	G.tick = function()
		return 1760000000 + Sched.now
	end
	G.time = function()
		return Sched.now
	end
	G.elapsedTime = G.time
	G.os = {
		clock = function()
			return Sched.now
		end,
		time = function(t)
			if t then
				return os.time(t)
			end
			return 1760000000 + math.floor(Sched.now)
		end,
		date = os.date,
		difftime = os.difftime,
	}
	G.settings = function()
		Rt.note("settings() called (not emulated)")
		return nil
	end
	G.UserSettings = function()
		Rt.note("UserSettings() called (not emulated)")
		return nil
	end
	G.shared = {}
	G._G = {}
	G.Vector2 = roblox.Vector2
	G.Vector3 = roblox.Vector3
	G.Vector2int16 = roblox.Vector2int16
	G.Vector3int16 = roblox.Vector3int16
	G.CFrame = Rt.CFrame
	G.UDim = roblox.UDim
	G.UDim2 = roblox.UDim2
	G.Color3 = roblox.Color3
	G.ColorSequence = roblox.ColorSequence
	G.ColorSequenceKeypoint = roblox.ColorSequenceKeypoint
	G.NumberSequence = roblox.NumberSequence
	G.NumberSequenceKeypoint = roblox.NumberSequenceKeypoint
	G.NumberRange = roblox.NumberRange
	G.Rect = roblox.Rect
	G.Ray = roblox.Ray
	G.BrickColor = roblox.BrickColor
	G.Font = roblox.Font
	G.Content = Rt.Content
	G.Region3 = roblox.Region3
	G.Region3int16 = roblox.Region3int16
	G.Faces = roblox.Faces
	G.Axes = roblox.Axes
	G.PhysicalProperties = roblox.PhysicalProperties
	G.TweenInfo = Rt.TweenInfo
	G.Random = Rt.Random
	G.RaycastParams = Rt.RaycastParams
	G.OverlapParams = Rt.OverlapParams
	G.DateTime = {
		now = function()
			return Rt.record("DateTime", { UnixTimestamp = 1760000000 + math.floor(Sched.now), UnixTimestampMillis = (1760000000 + Sched.now) * 1000 })
		end,
	}
	G.require = Loader.require
	return G
end

-------------------------------------------------------------------------------
-- require

function Loader.envFor(scriptInst: any): any
	return setmetatable({ script = scriptInst }, { __index = G })
end

function Loader.compile(inst: any): any
	local r = recs[inst]
	local path = r.source
	if not path then
		error("module has no source: " .. Rt.fullName(r), 3)
	end
	local src = r.sourceText
	if src == nil then
		error("module source was not preloaded: " .. path, 3)
	end
	if string.match(path, "%.json$") then
		local data = serde.decode("json", src)
		return function()
			return data
		end
	end
	return luau.load(src, { debugName = "=" .. path, environment = Loader.envFor(inst), injectGlobals = false })
end

function Loader.require(target: any): any
	local r = recs[target]
	if not r then
		if type(target) == "number" then
			error("require(assetId) is not supported in the smoke harness", 2)
		end
		error("Attempted to call require with invalid argument(s).", 2)
	end
	if r.class ~= "ModuleScript" then
		error("Attempted to call require with invalid argument(s).", 2)
	end
	local cached = Loader.loaded[target]
	if cached ~= nil then
		return cached.value
	end
	if Loader.loading[target] then
		error("Requested module was required recursively: " .. Rt.fullName(r), 2)
	end
	local failed = Loader.failed[target]
	if failed then
		error("Requested module experienced an error while loading (" .. tostring(r.source) .. ")", 2)
	end
	Loader.loading[target] = true
	Loader.requireCount += 1
	local fn = Loader.compile(target)
	local results = table.pack(pcall(fn))
	Loader.loading[target] = nil
	if not results[1] then
		Loader.failed[target] = tostring(results[2])
		error(results[2], 0)
	end
	table.remove(results, 1)
	results.n -= 1
	if results.n ~= 1 then
		error(string.format("Module code did not return exactly one value (%s)", r.source), 2)
	end
	Loader.loaded[target] = { value = results[1] }
	return results[1]
end

-- Runs a LocalScript in its own thread (like the engine would).
function Loader.runScript(inst: any)
	local fn = Loader.compile(inst)
	local co = coroutine.create(fn)
	Sched.label(co, "LocalScript " .. Rt.fullName(recs[inst]))
	Sched.resume(co)
	return co
end

local _ = exists
return Loader
