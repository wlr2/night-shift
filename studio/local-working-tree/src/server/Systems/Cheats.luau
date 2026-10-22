--!strict
-- QA cheats. Authorised only in Studio or for allow-listed developer UserIds;
-- the gate is checked server-side in every call. Cheats call the same system
-- APIs as real gameplay so QA exercises the real code paths.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Layout = require(ReplicatedStorage.Shared.Layout)
local Net = require(ReplicatedStorage.Shared.Net)
local Server = script.Parent.Parent
local Guard = require(Server.Util.Guard)
local Minigames = require(Server.Minigames)
local GameState = require(script.Parent.GameState)
local Drives = require(script.Parent.Drives)
local Power = require(script.Parent.Power)
local Doors = require(script.Parent.Doors)
local Workstation = require(script.Parent.Workstation)
local Threat = require(script.Parent.Threat)
local PlayerStatus = require(script.Parent.PlayerStatus)
local Checkpoints = require(script.Parent.Checkpoints)
local Finale = require(script.Parent.Finale)
local EventDirector = require(script.Parent.EventDirector)

local Cheats = {}

local function authorized(player: Player): boolean
	if RunService:IsStudio() then
		return true
	end
	return Config.DEV_USER_IDS[player.UserId] == true
end

local TELEPORTS: { [string]: Vector3 } = {
	office = Vector3.new(12, 3, 9),
	workstation = Vector3.new(15.5, 3, -7.5),
	kitchen = Vector3.new(-26, 3, -8),
	hall = Vector3.new(28, 3, 6),
	alley = Vector3.new(45, 3, 6),
	lobby = Vector3.new(12, 3, 19),
	rack = Vector3.new(10.4, 3, -10),
}

-- Finish the docked job through the minigame wrapper (QA shortcut).
local function completeDocked(): boolean
	local d = Drives.dockDrive()
	if not d then
		return false
	end
	if d.state == "Docked" then
		Drives.beginProcessing(d)
	end
	if d.job then
		d.job.complete = true
		return Drives.markErased(d)
	end
	return false
end

-- A simulated second actor for Studio authority tests. It is NOT a real
-- network client; it only has what the server logic reads from a Player.
local function fakeActor(name: string, pos: Vector3): any
	local attrs: { [string]: any } = {}
	local character = Instance.new("Model")
	character.Name = name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = true
	root.Transparency = 1
	root.CFrame = CFrame.new(pos)
	root.Parent = character
	local h = Instance.new("Humanoid")
	h.Parent = character
	character.Parent = workspace
	local actor = {
		Name = name,
		DisplayName = name,
		UserId = -1,
		Parent = Players,
		Character = character,
	}
	function actor.GetAttribute(_self: any, k: string)
		return attrs[k]
	end
	function actor.SetAttribute(_self: any, k: string, v: any)
		attrs[k] = v
	end
	function actor.Destroy(self: any)
		Guard.forget(self)
		character:Destroy()
	end
	return actor
end

local commands: { [string]: (player: Player, arg: any) -> string } = {
	-- two actors try to take the same drive in the same frame
	raceDrive = function(player)
		local target = nil
		for _, d in Drives.list do
			if d.state == "Installed" then
				target = d
				break
			end
		end
		if not target then
			return "no installed drive"
		end
		target.pcOff = true
		local root = Guard.rootOf(player)
		local fake = fakeActor("SimActor", if root then root.Position + Vector3.new(2, 0, 0) else Vector3.new(0, 3, 0))
		local a = Drives.pickup(player, target)
		local b = Drives.pickup(fake :: any, target)
		local owner = if target.carrier == player then "real" elseif target.carrier == fake then "sim" else "none"
		Drives.recoverFor(player, "QA")
		Drives.recoverFor(fake :: any, "QA")
		fake:Destroy()
		return string.format("real=%s sim=%s owner=%s state=%s (exactly one must win)", tostring(a), tostring(b), owner, target.state)
	end,
	-- a second actor (not seated) sends desktop actions with the live session id
	secondOperator = function(player)
		local op = Workstation.operator()
		if op ~= player then
			return "sit at the workstation first"
		end
		local d = Drives.dockDrive()
		local before = if d and d.job then d.job.actions else -1
		local fake = fakeActor("SimActor2", Vector3.new(16, 3, -7))
		Workstation.handleDesktop(fake, Workstation.sessionId(), "act", "press", 1, nil)
		Workstation.handleDesktop(fake, Workstation.sessionId(), "start", nil, nil, nil)
		local after = if d and d.job then d.job.actions else -1
		local stillOp = Workstation.operator() == player
		fake:Destroy()
		return string.format("actions before=%d after=%d operator unchanged=%s (sim actor must be rejected)", before, after, tostring(stillOp))
	end,
	-- the real operator replays an action with an outdated session id
	staleSession = function(player)
		local d = Drives.dockDrive()
		local before = if d and d.job then d.job.actions else -1
		Workstation.handleDesktop(player, Workstation.sessionId() - 1, "act", "press", 1, nil)
		local after = if d and d.job then d.job.actions else -1
		return string.format("stale action: actions before=%d after=%d (must be equal)", before, after)
	end,
	state = function()
		local s = EventDirector.debugState()
		return string.format("phase=%s erased=%d active=%s nextRoll=%.0f recovery=%.0f threat=%s", GameState.phase, GameState.data.erased, table.concat(s.active, ","), s.nextRollIn, s.recoveryFor, Threat.mode())
	end,
	log = function()
		return table.concat(EventDirector.debugState().log, "\n")
	end,
	erase = function()
		return if completeDocked() then "erased docked drive" else "no docked drive"
	end,
	eraseAll = function(_p, n)
		local count = if typeof(n) == "number" then n else 6
		for _, d in Drives.list do
			if Drives.erasedCount() >= count then
				break
			end
			if d.state ~= "Erased" then
				local busy = Drives.dockDrive()
				if busy and busy ~= d then
					completeDocked()
				end
				-- move through the real state machine
				d.pcOff = true
				d.state = "Docked"
				Drives.beginProcessing(d)
				if d.job then
					d.job.complete = true
					Drives.markErased(d)
				end
			end
		end
		return "erased=" .. Drives.erasedCount()
	end,
	event = function(_p, id)
		return if typeof(id) == "string" and EventDirector.trigger(id) then "started " .. id else "could not start"
	end,
	power = function()
		Power.trip({ "MAIN" })
		return "MAIN tripped"
	end,
	door = function()
		Doors.set("Ajar")
		return "door ajar"
	end,
	hunt = function()
		Threat.hunt(15)
		return "hunting"
	end,
	finale = function()
		Finale.debugBeginFinalPurge()
		return "final purge"
	end,
	signoff = function(_p, p)
		Finale.debugBeginSignOff(if typeof(p) == "number" then p else 0.9)
		return "sign-off"
	end,
	clockout = function()
		Finale.debugBeginClockOut()
		return "clock out"
	end,
	down = function(player)
		PlayerStatus.down(player, "cheat")
		return "downed"
	end,
	restore = function()
		task.spawn(Checkpoints.restore, "cheat")
		return "restoring"
	end,
	tp = function(player, where)
		local pos = if typeof(where) == "string" then TELEPORTS[where] else nil
		local root = Guard.rootOf(player)
		if pos and root then
			root.CFrame = CFrame.new(pos)
			return "teleported"
		end
		return "unknown place"
	end,
	solve = function()
		-- performs one CORRECT semantic action via the minigame API (tests validation path)
		local d = Drives.dockDrive()
		if not d or not d.job then
			return "no job"
		end
		local s = d.job.state
		local data = s.data
		local res
		if d.game == "FileSort" then
			for _, f in data.files do
				if not f.bin then
					res = Minigames.perform(d.job, "sort", f.id, f.target)
					break
				end
			end
		elseif d.game == "Checksum" then
			res = Minigames.perform(d.job, "match", data.answer, nil)
		elseif d.game == "MemorySequence" then
			res = Minigames.perform(d.job, "press", data.seq[data.input + 1], nil)
		elseif d.game == "SectorRepair" then
			for i, idx in data.current do
				if idx ~= data.target[i] then
					for j, other in data.current do
						if other == data.target[i] then
							res = Minigames.perform(d.job, "swap", i, j)
							break
						end
					end
					break
				end
			end
		elseif d.game == "ProcessCleanup" then
			for gi, g in data.groups do
				if g.unlocked and not g.deleted then
					res = Minigames.perform(d.job, "purge", gi, nil)
					break
				end
			end
			if not res then
				for _, p in data.procs do
					if p.target and not p.ended then
						res = Minigames.perform(d.job, "kill", p.pid, nil)
						break
					end
				end
			end
		elseif d.game == "SignalRouting" then
			for i, t in data.tiles do
				local sol = data.solved[i]
				if data.onPath[i] then
					local okNow = true
					for _ = 1, 4 do
						-- rotate until this path tile matches its solved connections
						local same = true
						for dir = 1, 4 do
							local function conn(tile: any, dd: number): boolean
								local base = ({ I = { 1, 3 }, L = { 1, 2 }, T = { 1, 2, 3 } })[tile.kind]
								for _, b in base do
									if (b - 1 + tile.rot) % 4 + 1 == dd then
										return true
									end
								end
								return false
							end
							if conn(t, dir) ~= conn(sol, dir) then
								same = false
							end
						end
						if same then
							break
						end
						okNow = false
						res = Minigames.perform(d.job, "rotate", i, nil)
					end
					if not okNow then
						break
					end
				end
			end
		end
		if d.job.complete then
			Drives.markErased(d)
		end
		Workstation.push()
		return if res then res.kind .. ": " .. res.message else "nothing to do"
	end,
}

function Cheats.init()
	Net.remote("Cheat").OnServerEvent:Connect(function(player, cmd: unknown, arg: unknown)
		if not authorized(player) then
			return
		end
		local rate = Config.RATE.cheat
		if not Guard.allow(player, "cheat", rate[1], rate[2]) then
			return
		end
		if typeof(cmd) ~= "string" then
			return
		end
		local fn = commands[cmd :: string]
		if fn then
			local ok, out = pcall(fn, player, arg)
			GameState.notify(player, "[cheat] " .. tostring(out), "info")
			print("[Cheat]", player.Name, cmd, ok, out)
		end
	end)
	-- Studio-only QA hook: a BindableFunction in ServerStorage lets test
	-- scripts in the Studio server context drive the LIVE systems (requiring
	-- modules from the command bar would create separate copies). Never
	-- created outside Studio; not reachable from clients.
	if RunService:IsStudio() then
		local bf = Instance.new("BindableFunction")
		bf.Name = "NightShiftQA"
		bf.OnInvoke = function(cmd: string, arg: any, userId: number?)
			local player = if userId then Players:GetPlayerByUserId(userId) else Players:GetPlayers()[1]
			local fn = commands[cmd]
			if not fn or not player then
				return "no such command/player"
			end
			local ok, out = pcall(fn, player, arg)
			return (if ok then "" else "ERR ") .. tostring(out)
		end
		bf.Parent = game:GetService("ServerStorage")
	end
	local _l = Layout
end

-- Exposed for in-place server QA scripts run by the developer in Studio.
Cheats.commands = commands
Cheats.authorized = authorized

return Cheats
