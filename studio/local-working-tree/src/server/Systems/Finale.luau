--!strict
-- The guaranteed climax and ending, triggered by job progress (6/6 erased):
--   FinalPurge  the queue lists the team's own records: cancel them in time
--   SignOff     finite emergency sign-off; pauses (never resets) without
--               power; operator confirms milestones (each is a checkpoint)
--   ClockOut    time clock unlocks; slow pursuit; team clocks out and leaves
--   Ending      ending screen, then a fresh round
-- The goal and completion conditions are fixed; interruptions come from the
-- event director, which caps them during the finale so it always finishes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Dialogue = require(ReplicatedStorage.Shared.Dialogue)
local Layout = require(ReplicatedStorage.Shared.Layout)
local Server = script.Parent.Parent
local Guard = require(Server.Util.Guard)
local Prompts = require(Server.Util.Prompts)
local GameState = require(script.Parent.GameState)
local MapBuilder = require(script.Parent.MapBuilder)
local Power = require(script.Parent.Power)
local Doors = require(script.Parent.Doors)
local Drives = require(script.Parent.Drives)
local Workstation = require(script.Parent.Workstation)
local Threat = require(script.Parent.Threat)
local PlayerStatus = require(script.Parent.PlayerStatus)
local Checkpoints = require(script.Parent.Checkpoints)

local Finale = {}

local token = 0
local clockPrompt: ProximityPrompt
local firstClockOut: number? = nil
local shiftStartClock = os.clock()

local CREW = { "D. MERRIN (2003)", "A. OSEI (2003)", "P. LIND (2003)", "J. RUIZ (2003)" }

local function allCancelled(): boolean
	local list = GameState.data.purge
	if not list then
		return false
	end
	for _, e in list do
		if not e.locked and not e.cancelled then
			return false
		end
	end
	return true
end

local function buildPurgeList()
	local list = {}
	for _, name in CREW do
		table.insert(list, { name = name, cancelled = false, locked = true })
	end
	for _, p in Players:GetPlayers() do
		table.insert(list, { name = string.upper(p.DisplayName) .. " (tonight)", cancelled = false, locked = false, userId = p.UserId })
	end
	GameState.data.purge = list
end

local beginSignOff: (progress: number) -> ()
local beginClockOut: () -> ()

local function beginFinalPurge()
	token += 1
	local my = token
	GameState.setPhase("FinalPurge")
	buildPurgeList()
	local solo = GameState.isSolo()
	GameState.data.purgeDeadline = os.clock() + (if solo then Config.PHASE.finalPurgeCountdown.solo else Config.PHASE.finalPurgeCountdown.coop)
	GameState.bossMessage(Dialogue.FINAL_PURGE, "system", nil, "SecureErase")
	task.delay(3, function()
		if token == my then
			GameState.bossMessage(Dialogue.FINAL_PURGE_BOSS, "story")
		end
	end)
	GameState.fx("FinalPurge", nil)
	GameState.markDirty()
	Workstation.push()
	task.spawn(function()
		while token == my and GameState.phase == "FinalPurge" do
			task.wait(0.5)
			GameState.markDirty()
			-- the queue cannot be cancelled without power, so the countdown pauses too
			if not Power.workstationOn() and GameState.data.purgeDeadline then
				GameState.data.purgeDeadline += 0.5
			end
			local deadline = GameState.data.purgeDeadline
			if deadline and os.clock() > deadline and not allCancelled() then
				GameState.fx("PurgeExecuted", nil)
				GameState.notify(nil, "FINAL PURGE EXECUTED. Your records are gone...", "bad")
				task.wait(2)
				if token == my then
					Checkpoints.restore("final purge executed")
				end
				return
			end
		end
	end)
end

beginSignOff = function(progress: number)
	token += 1
	local my = token
	GameState.setPhase("SignOff")
	GameState.data.signOff = { progress = progress, awaiting = false, paused = false }
	GameState.data.purgeDeadline = nil
	GameState.bossMessage(Dialogue.SIGNOFF_START, "system", nil, "SecureErase")
	task.delay(4, function()
		if token == my then
			GameState.bossMessage(Dialogue.SIGNOFF_BOSS, "story")
		end
	end)
	GameState.fx("SignOffStart", nil)
	Workstation.push()
	local duration = if GameState.isSolo() then Config.PHASE.signOffSeconds.solo else Config.PHASE.signOffSeconds.coop
	task.spawn(function()
		local last = os.clock()
		local lastShown, lastPaused = -1, false
		while token == my and GameState.phase == "SignOff" do
			task.wait(0.2)
			local now = os.clock()
			local dt = now - last
			last = now
			local s = GameState.data.signOff
			if not s then
				return
			end
			s.paused = not Power.workstationOn() or s.awaiting
			if not s.paused then
				local before = s.progress
				s.progress = math.min(1, s.progress + dt / duration)
				for _, m in Config.PHASE.signOffConfirmAt do
					if before < m and s.progress >= m then
						s.progress = m
						s.awaiting = true
						GameState.fx("SignOffConfirm", { at = m })
						GameState.notify(nil, string.format("Sign-off paused at %d%%: the operator must CONFIRM at the workstation.", math.floor(m * 100)), "info")
						break
					end
				end
				if s.progress >= 1 then
					beginClockOut()
					return
				end
			end
			local shown = math.floor(s.progress * 100)
			if shown ~= lastShown or s.paused ~= lastPaused then
				lastShown = shown
				lastPaused = s.paused
				GameState.markDirty()
				Workstation.push()
			end
		end
	end)
end

beginClockOut = function()
	token += 1
	local my = token
	GameState.setPhase("ClockOut")
	GameState.data.signOff = { progress = 1, awaiting = false, paused = false }
	GameState.data.clockedOut = {}
	firstClockOut = nil
	for _, p in Players:GetPlayers() do
		p:SetAttribute("ClockedOut", false)
	end
	Checkpoints.save("sign-off complete", { clockOut = true })
	GameState.bossMessage(Dialogue.CLOCKOUT, "system", nil, "SecureErase")
	GameState.fx("ClockOutStart", nil)
	Workstation.push()
	clockPrompt.ActionText = "Clock out"
	task.delay(7, function()
		if token == my and GameState.phase == "ClockOut" then
			Threat.pursue()
		end
	end)
	-- escape detection + door timing
	task.spawn(function()
		local Z = Layout.ESCAPE_ZONE
		while token == my and GameState.phase == "ClockOut" do
			task.wait(0.25)
			if firstClockOut and not GameState.data.frontDoorOpen and os.clock() - firstClockOut > Config.PHASE.clockOutUnlockAfterFirst then
				Doors.openFront()
			end
			for _, p in Players:GetPlayers() do
				local r = Guard.rootOf(p)
				if r and p:GetAttribute("Escaped") ~= true and GameState.data.frontDoorOpen then
					local pos = r.Position
					if pos.X >= Z.minX and pos.X <= Z.maxX and pos.Z >= Z.minZ and pos.Z <= Z.maxZ then
						PlayerStatus.setEscaped(p, true)
						GameState.fx("Escaped", { name = p.DisplayName })
					end
				end
			end
			-- ending when nobody is left inside; downed stragglers are carried out
			local inside, standingInside = 0, 0
			for _, p in Players:GetPlayers() do
				if p:GetAttribute("Escaped") ~= true then
					inside += 1
					if not PlayerStatus.isDowned(p) then
						standingInside += 1
					end
				end
			end
			if #Players:GetPlayers() > 0 and (inside == 0 or (standingInside == 0 and inside < #Players:GetPlayers())) then
				for _, p in Players:GetPlayers() do
					if p:GetAttribute("Escaped") ~= true then
						PlayerStatus.revive(p, nil)
						PlayerStatus.setEscaped(p, true)
					end
				end
				Finale.ending()
				return
			end
		end
	end)
end

function Finale.ending()
	token += 1
	local my = token
	GameState.setPhase("Ending")
	Threat.despawn()
	GameState.clearThreats()
	local elapsed = os.clock() - shiftStartClock
	GameState.fx("Ending", {
		title = Dialogue.ENDING.title,
		lines = Dialogue.ENDING.lines,
		minutes = math.floor(elapsed / 60),
		seconds = math.floor(elapsed % 60),
	})
	task.delay(Config.PHASE.endingSeconds, function()
		if token == my then
			Finale.resetRound()
		end
	end)
end

function Finale.resetRound()
	token += 1
	local d = GameState.data
	d.erased = 0
	d.fragments = {}
	d.boss = {}
	d.purge = nil
	d.purgeDeadline = nil
	d.signOff = nil
	d.clockedOut = {}
	d.roundStart = os.clock()
	d.round += 1
	shiftStartClock = os.clock()
	clockPrompt.ActionText = "Clock out"
	GameState.clearThreats()
	GameState.RoundReset:Fire()
	PlayerStatus.respawnAll()
	GameState.markDirty()
end

local function onClockOut(player: Player)
	if GameState.phase ~= "ClockOut" then
		GameState.notify(player, "The time clock won't accept your card until the shift is signed off.", "info")
		return
	end
	if player:GetAttribute("ClockedOut") == true then
		return
	end
	player:SetAttribute("ClockedOut", true)
	table.insert(GameState.data.clockedOut, player.DisplayName)
	GameState.fx("ClockedOut", { name = player.DisplayName })
	firstClockOut = firstClockOut or os.clock()
	local all = true
	for _, p in PlayerStatus.standing() do
		if p:GetAttribute("ClockedOut") ~= true then
			all = false
		end
	end
	if all then
		Doors.openFront()
	end
	GameState.markDirty()
end

-- Desktop commands --------------------------------------------------------

local function cmdPurgeCancel(_player: Player, a: any, _b: any): (string?, string?)
	if GameState.phase ~= "FinalPurge" then
		return nil
	end
	local list = GameState.data.purge
	if not list or typeof(a) ~= "number" or a ~= math.floor(a) or a < 1 or a > #list then
		return nil
	end
	local e = list[a]
	if e.locked then
		return "Record already purged in 2003. Cannot cancel.", "bad"
	end
	if e.cancelled then
		return nil
	end
	e.cancelled = true
	GameState.markDirty()
	if allCancelled() then
		return "All of tonight's staff records removed from the queue. Run EMERGENCY SIGN-OFF.", "good"
	end
	return e.name .. " removed from the purge queue.", "good"
end

local function cmdSignOffStart(_player: Player, _a: any, _b: any): (string?, string?)
	if GameState.phase ~= "FinalPurge" or not allCancelled() then
		return "Cancel every record from tonight first.", "bad"
	end
	Checkpoints.save("emergency sign-off started", { signOff = 0 })
	beginSignOff(0)
	return "Emergency sign-off running.", "good"
end

local function cmdSignOffConfirm(_player: Player, _a: any, _b: any): (string?, string?)
	local s = GameState.data.signOff
	if GameState.phase ~= "SignOff" or not s or not s.awaiting then
		return nil
	end
	s.awaiting = false
	Checkpoints.save(string.format("sign-off %d%%", math.floor(s.progress * 100)), { signOff = s.progress })
	return "Checkpoint confirmed. Sign-off continuing.", "good"
end

function Finale.init()
	clockPrompt = Prompts.make(MapBuilder.refs.timeClock, { action = "Clock out", object = "Time clock", hold = 0.6, distance = 8 })
	clockPrompt.Triggered:Connect(function(player)
		if Prompts.valid(player, clockPrompt, "clock") then
			onClockOut(player)
		end
	end)
	Workstation.registerCommand("purgeCancel", cmdPurgeCancel)
	Workstation.registerCommand("signOffStart", cmdSignOffStart)
	Workstation.registerCommand("signOffConfirm", cmdSignOffConfirm)

	Drives.Erased:Connect(function(_d, count)
		if count >= Config.DRIVE_COUNT and GameState.phase == "Work" then
			task.delay(4, function()
				if GameState.phase == "Work" and Drives.erasedCount() >= Config.DRIVE_COUNT then
					GameState.bossMessage(Dialogue.BOSS_PROGRESS[6], "story")
					Checkpoints.save("before the finale", { finalPurge = true })
					-- checkpoint phase should be FinalPurge so a wipe returns here
					local cp = Checkpoints.latest()
					if cp then
						cp.phase = "FinalPurge"
					end
					beginFinalPurge()
				end
			end)
		end
	end)

	Checkpoints.Restoring:Connect(function()
		token += 1 -- stop finale loops; Restored decides what to resume
		Threat.despawn()
	end)
	Checkpoints.Restored:Connect(function(cp)
		if not cp then
			return
		end
		local signOff = cp.extra.signOff
		if cp.extra.clockOut then
			beginClockOut()
		elseif typeof(signOff) == "number" then
			beginSignOff(signOff)
		elseif cp.phase == "FinalPurge" then
			beginFinalPurge()
		end
	end)

	Players.PlayerAdded:Connect(function(p)
		if GameState.phase == "FinalPurge" and GameState.data.purge then
			table.insert(GameState.data.purge, { name = string.upper(p.DisplayName) .. " (tonight)", cancelled = false, locked = false, userId = p.UserId })
			GameState.markDirty()
		end
	end)
	Players.PlayerRemoving:Connect(function(p)
		local list = GameState.data.purge
		if list then
			for i, e in list do
				if (e :: any).userId == p.UserId then
					table.remove(list, i)
					break
				end
			end
			GameState.markDirty()
		end
	end)
end

-- QA hooks (used only by the gated Cheats system)
Finale.debugBeginFinalPurge = beginFinalPurge
Finale.debugBeginSignOff = function(p: number)
	beginSignOff(p)
end
Finale.debugBeginClockOut = function()
	beginClockOut()
end

return Finale
