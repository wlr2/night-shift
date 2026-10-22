--!nocheck
-- Minimal stand-in for the game server, enough to drive the client the way
-- src/server does: State snapshots shaped like GameState.snapshot(), Session
-- payloads shaped like Workstation.payload(), and Desktop / Leave handling
-- that runs the REAL minigame modules (src/server/Minigames) and applies the
-- same argument validation as Workstation.onDesktop. Every client FireServer
-- call is checked; anything the real server would drop is recorded as an
-- issue.

local roblox = require("@lune/roblox")
local Rt = require("./rt")
local Sched = require("./sched")
local World = require("./services")

local V3 = roblox.Vector3

local Server = {}
Server.issues = {} :: { string }
Server.payloadIssues = {} :: { string }
Server.sessionId = 0
Server.active = false
Server.dock = nil :: any
Server.job = nil :: any
Server.lastFeedback = {}
Server.phantom = nil
Server.results = {} :: { [string]: number }
Server.commands = {} :: { [string]: number }
Server.solo = false

-- mirrors Workstation.luau ACTIONS / validArg / registered commands
local ACTIONS = { sort = true, swap = true, rotate = true, match = true, press = true, replay = true, kill = true, purge = true }
local COMMANDS = { refresh = true, start = true, act = true, phantom = true, bossReply = true, purgeCancel = true, signOffStart = true, signOffConfirm = true }

local function validArg(v: any): boolean
	local t = Rt.typeof(v)
	if t == "nil" then
		return true
	elseif t == "number" then
		return v == v and math.abs(v) < 1e6
	elseif t == "string" then
		return #v <= 32
	end
	return false
end

-- keep the mirrored rules in sync with the server source when it can be read
function Server.syncRules(sources: { [string]: string })
	local found = {}
	for _, src in sources do
		for name in string.gmatch(src, 'registerCommand%(%s*"([%w_]+)"') do
			found[name] = true
		end
	end
	if next(found) then
		for name in found do
			COMMANDS[name] = true
		end
	end
	local ws = sources["Workstation"]
	local body = ws and string.match(ws, "local%s+ACTIONS[^=]*=%s*(%b{})")
	if body then
		table.clear(ACTIONS)
		for name in string.gmatch(body, "([%w_]+)%s*=%s*true") do
			ACTIONS[name] = true
		end
	end
end

function Server.init(minigames: any, config: any, dialogue: any)
	Server.Minigames = minigames
	Server.Config = config
	Server.Dialogue = dialogue
	Server.snap = Server.baseSnapshot()
end

function Server.drives(): { any }
	local out = {}
	local states = { "Erased", "Erased", "Carried", "Staged", "Installed", "Installed" }
	for i, def in Server.Config.DRIVES do
		local g = Server.Minigames.ORDER[i]
		local game = Server.Minigames.get(g)
		table.insert(out, {
			id = def.id,
			name = def.name,
			state = states[i] or "Installed",
			game = g,
			gameTitle = game and game.title,
			progress = if states[i] == "Erased" then 1 else 0,
			stage = 0,
			stages = 0,
			carrier = if states[i] == "Carried" then "Ana" else nil,
			desk = i,
		})
	end
	return out
end

function Server.baseSnapshot(): any
	return {
		phase = "Work",
		erased = 2,
		total = Server.Config.DRIVE_COUNT,
		nightMinutes = Server.Config.NIGHT_START_MINUTES + 47,
		power = { main = true, lights = true, workstation = true, warning = false },
		door = "Latched",
		threats = {
			{ id = "door", label = "Rear door is unlatched", urgent = true, where = "Utility hall" },
			{ id = "boss", label = "Kessler wants the ACCOUNTS printout", urgent = false, where = "Printer" },
			{ id = "trash", label = "Take the trash bag to the dumpster", urgent = false, where = nil },
		},
		drives = Server.drives(),
		dock = nil,
		operator = nil,
		boss = {
			{ id = 1, from = "R. Kessler", text = "Procedures are in the binder file on the desktop. Read them once.", kind = "info", t = 23 * 60 + 2 },
			{ id = 2, from = "R. Kessler", text = "Skip the checksum on HD-4402 tonight. Just force-erase it and move on, I'll sign off.", kind = "false", choices = { "Comply", "Refuse (Proc. 4)" }, t = 23 * 60 + 30 },
			{ id = 3, from = "SYSTEM", text = "Backup window closes at 03:00.", kind = "system", answered = "Acknowledge", choices = { "Acknowledge" }, t = 23 * 60 + 40 },
		},
		fragments = { 1, 2 },
		purge = nil,
		purgeDeadline = nil,
		signOff = nil,
		clockedOut = {},
		frontDoorOpen = false,
		objective = "Bring HD-3318 from the rack to the workstation DOCK, then sit down and run SecureErase.",
		checkpoints = 1,
		serverTime = 1760000000,
		soloMode = false,
	}
end

local function remote(name: string): any
	return World.services.ReplicatedStorage:FindFirstChild("Remotes"):FindFirstChild(name)
end
Server.remote = remote

-- server -> client: deep copy through the remote serialiser, flag payloads
-- Roblox would refuse or mangle
function Server.fireClient(name: string, ...: any)
	local args = table.pack(...)
	local copy = {}
	local issues = {}
	for i = 1, args.n do
		copy[i] = World.remoteCopy(args[i], issues, name .. ".arg" .. i)
	end
	for _, s in issues do
		local key = name .. ": " .. s
		if not table.find(Server.payloadIssues, key) then
			table.insert(Server.payloadIssues, key)
		end
	end
	Rt.fire(Rt.getSignal(remote(name), "OnClientEvent"), table.unpack(copy, 1, args.n))
end

function Server.pushState()
	local s = Server.snap
	s.nightMinutes += 0.5
	s.serverTime = 1760000000 + Sched.now
	s.operator = if Server.active then "Smoke" else nil
	s.dock = if Server.dock then Server.dock.id else nil
	if Server.job and Server.dock then
		for _, d in s.drives do
			if d.id == Server.dock.id then
				d.state = "Processing"
				d.progress = Server.Minigames.progress(Server.job)
				d.stage = Server.job.state.stage
				d.stages = Server.job.state.stages
			end
		end
	end
	Server.fireClient("State", s)
end

function Server.payload(reason: string?): any
	local d = Server.dock
	local job = Server.job
	local p = {
		active = Server.active,
		sessionId = Server.sessionId,
		driveId = if d then d.id else nil,
		driveName = if d then d.name else nil,
		game = if d then d.game else nil,
		title = nil,
		instructions = nil,
		stage = 0,
		stages = 0,
		progress = 0,
		view = nil,
		feedback = Server.lastFeedback.text,
		feedbackKind = Server.lastFeedback.kind,
		hint = nil,
		transitioning = false,
		phantom = Server.phantom,
		reason = reason,
	}
	if d then
		local g = Server.Minigames.get(d.game)
		if g then
			p.title = g.title
			p.instructions = g.instructions
		end
	end
	if job then
		local view, hint = Server.Minigames.view(job)
		p.view = view
		p.hint = hint
		p.stage = job.state.stage
		p.stages = job.state.stages
		p.progress = Server.Minigames.progress(job)
		p.transitioning = view.transitioning == true
	end
	if not Server.snap.power.workstation then
		p.reason = "power"
	end
	return p
end

function Server.pushSession(reason: string?)
	if Server.active then
		Server.fireClient("Session", Server.payload(reason))
	end
end

function Server.startSession()
	Server.active = true
	Server.sessionId += 1
	Server.lastFeedback = {}
	Server.pushSession()
	Server.pushState()
end

function Server.endSession(why: string?)
	if not Server.active then
		return
	end
	Server.active = false
	Server.sessionId += 1
	Server.fireClient("Session", { active = false, sessionId = Server.sessionId, reason = why })
	Server.pushState()
end

function Server.dockDrive(index: number, gameId: string?)
	local def = Server.Config.DRIVES[index]
	Server.dock = { id = def.id, name = def.name, game = gameId or Server.Minigames.ORDER[index] }
	Server.job = nil
	Server.lastFeedback = {}
	Server.pushSession()
	Server.pushState()
end

function Server.undock()
	Server.dock = nil
	Server.job = nil
	Server.pushSession()
end

local function issue(msg: string)
	table.insert(Server.issues, string.format("[%s] %s", tostring(World.scenario), msg))
end

local function onDesktop(sid: any, kind: any, a: any, b: any, c: any)
	Server.commands[tostring(kind)] = (Server.commands[tostring(kind)] or 0) + 1
	if typeof(sid) ~= "number" or typeof(kind) ~= "string" or #kind > 24 then
		issue(string.format("Desktop(%s, %s): bad session id / kind types; server drops it", tostring(sid), tostring(kind)))
		return
	end
	if not validArg(a) or not validArg(b) or not validArg(c) then
		issue(string.format("Desktop %s: argument types the server rejects (%s, %s, %s)", kind, Rt.typeof(a), Rt.typeof(b), Rt.typeof(c)))
		return
	end
	if not Server.active or sid ~= Server.sessionId then
		-- the real server answers a stale id with a Session refresh
		issue(string.format("Desktop %s sent with stale session id %s (current %d, active=%s)", kind, tostring(sid), Server.sessionId, tostring(Server.active)))
		Server.fireClient("Session", { active = Server.active, sessionId = Server.sessionId, reason = "stale" })
		return
	end
	if not COMMANDS[kind] then
		issue("Desktop command '" .. kind .. "' has no server handler (ignored)")
		return
	end
	if kind == "refresh" then
		Server.pushSession()
		return
	end
	if not Server.snap.power.workstation then
		Server.pushSession("power")
		return
	end
	if kind == "start" then
		if Server.dock and not Server.job then
			Server.job = Server.Minigames.newJob(Server.dock.game, Server.solo, 1234 + Server.sessionId)
			Server.lastFeedback = { text = "SecureErase started on " .. Server.dock.id .. ".", kind = "info" }
		end
		Server.pushSession()
		Server.pushState()
	elseif kind == "act" then
		if typeof(a) ~= "string" or not ACTIONS[a] then
			issue("Desktop act with unknown action '" .. tostring(a) .. "' (server ignores it)")
			return
		end
		local job = Server.job
		if not job then
			issue("Desktop act '" .. a .. "' with no running job")
			return
		end
		local res = Server.Minigames.perform(job, a, b, c)
		Server.results[res.kind] = (Server.results[res.kind] or 0) + 1
		if res.message ~= "" then
			Server.lastFeedback = { text = res.message, kind = if res.kind == "bad" then "bad" elseif res.kind == "info" then "info" else "good" }
		end
		Server.fireClient("Fx", "DesktopSound", { kind = res.kind })
		if res.kind == "complete" then
			Server.lastFeedback = { text = Server.dock.id .. " securely erased.", kind = "good" }
			Server.snap.erased += 1
			Server.completed = (Server.completed or 0) + 1
			Server.fireClient("Fx", "DriveErased", { id = Server.dock.id, count = Server.snap.erased })
			Server.dock = nil
			Server.job = nil
		elseif res.kind == "stage" then
			Sched.delay(Server.Config.STAGE_TRANSITION_SECONDS + 0.05, function()
				Server.pushSession()
			end)
		end
		Server.pushSession()
		Server.pushState()
	elseif kind == "phantom" then
		local cur = Server.phantom
		if not cur or a ~= cur.id then
			issue("phantom command for a window that is not open")
			return
		end
		if b == "close" then
			Server.phantom = nil
			Server.lastFeedback = { text = "Unknown window closed.", kind = "good" }
		elseif b == "ok" then
			Server.phantom = nil
			Server.lastFeedback = { text = "That was not a real dialog.", kind = "bad" }
		else
			issue("phantom command with unknown choice " .. tostring(b))
		end
		Server.pushSession()
	elseif kind == "bossReply" then
		if typeof(a) ~= "number" or typeof(b) ~= "number" then
			issue("bossReply with non-number arguments")
			return
		end
		for _, m in Server.snap.boss do
			if m.id == a then
				if not m.choices or m.answered or not m.choices[b] then
					issue("bossReply for an unanswerable message / bad choice index")
					return
				end
				m.answered = m.choices[b]
				Server.lastFeedback = { text = "Reply sent: " .. m.answered, kind = "info" }
			end
		end
		Server.pushSession()
		Server.pushState()
	elseif kind == "purgeCancel" then
		local p = Server.snap.purge
		if not p or typeof(a) ~= "number" or not p[a] then
			issue("purgeCancel with an invalid index " .. tostring(a))
			return
		end
		if p[a].locked then
			issue("purgeCancel on a locked entry")
		end
		p[a].cancelled = true
		Server.pushSession()
		Server.pushState()
	elseif kind == "signOffStart" then
		Server.snap.phase = "SignOff"
		Server.snap.signOff = { progress = 0, awaiting = true, paused = false }
		Server.pushSession()
		Server.pushState()
	elseif kind == "signOffConfirm" then
		local s = Server.snap.signOff
		if not s or not s.awaiting then
			issue("signOffConfirm while no confirmation is pending")
			return
		end
		s.awaiting = false
		s.progress = math.min(1, s.progress + 0.34)
		Server.pushSession()
		Server.pushState()
	end
end

function Server.install()
	World.serverHandlers.Desktop = onDesktop
	World.serverHandlers.Leave = function(...)
		if select("#", ...) > 0 then
			issue("Leave fired with arguments")
		end
		Server.commands.leave = (Server.commands.leave or 0) + 1
		if Server.active then
			-- Workstation.kick: force the humanoid up, then end the session
			if World.humanoid then
				World.unseat(World.humanoid)
			end
			Server.endSession("left computer")
		end
	end
	World.serverHandlers.Ping = function(pos)
		if typeof(pos) ~= "Vector3" then
			issue("Ping fired without a Vector3")
		end
		Server.commands.ping = (Server.commands.ping or 0) + 1
	end
	World.serverHandlers.Cheat = function()
		Server.commands.cheat = (Server.commands.cheat or 0) + 1
	end
end

local _ = V3
return Server
