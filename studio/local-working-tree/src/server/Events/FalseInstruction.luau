--!strict
-- FALSE INSTRUCTION: a boss message that contradicts a numbered procedure.
-- The evidence is always available (Procedures.txt on the desktop, notices
-- in the building), so players can reject it instead of guessing.
-- Complying has a forgiving consequence; rejecting earns a calm window.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Dialogue = require(ReplicatedStorage.Shared.Dialogue)
local Server = script.Parent.Parent
local Systems = Server.Systems
local Minigames = require(Server.Minigames)
local GameState = require(Systems.GameState)
local Doors = require(Systems.Doors)
local Power = require(Systems.Power)
local Drives = require(Systems.Drives)
local Workstation = require(Systems.Workstation)

local cfg = Config.EVENTS.FalseInstruction

local pending: { msgId: number, template: Dialogue.FalseInstruction, finish: (string) -> () }? = nil
local used: { [string]: boolean } = {}

local FalseInstruction = {
	id = "FalseInstruction",
	urgent = false,
	mechanic = "false",
	cooldown = cfg.cooldown,
	conflicts = { "BossRequest" },
}

local function resolve(choice: string)
	local p = pending
	if not p then
		return
	end
	pending = nil
	local t = p.template
	if string.sub(choice, 1, 6) == "Reject" then
		GameState.bossMessage(t.reply, "story")
		GameState.notify(nil, "Instruction rejected (Procedure " .. t.procedure .. "). Things feel calmer for a moment.", "good")
		local director = require(Systems.EventDirector) :: any
		director.grantRecovery(25)
		p.finish("success")
		return
	end
	-- complied: forgiving consequences only
	if t.id == "door" or t.id == "dumpster" then
		Doors.set("Ajar")
	elseif t.id == "main" then
		Power.warnThenTrip({ "MAIN" }, 2)
	elseif t.id == "force" then
		local d = Drives.dockDrive()
		if d and d.job then
			Minigames.setback(d.job)
			GameState.notify(nil, "FORCE ERASE corrupted the current stage. It has been restarted (earlier stages are safe).", "bad")
			Workstation.push()
		end
	end
	GameState.bossMessage("Good.", "story")
	p.finish("failure")
end

function FalseInstruction.setup()
	Workstation.registerCommand("bossReply", function(player, a, b)
		if typeof(a) ~= "number" or typeof(b) ~= "number" then
			return nil
		end
		local m = GameState.findBoss(a)
		if not m or not m.choices or m.answered then
			return nil
		end
		local choice = m.choices[b]
		if not choice then
			return nil
		end
		if GameState.answerBoss(a, choice, player) then
			return "Reply sent: " .. choice, "info"
		end
		return nil
	end)
	GameState.BossAnswered:Connect(function(id, choice)
		if pending and pending.msgId == id then
			resolve(choice)
		end
	end)
	GameState.RoundReset:Connect(function()
		pending = nil
		table.clear(used)
	end)
end

function FalseInstruction.eligible(ctx: any): boolean
	return ctx.phase == "Work" and pending == nil and ctx.erased >= cfg.minErased
end

function FalseInstruction.weight(_ctx: any): number
	return cfg.weight
end

function FalseInstruction.start(ctx: any, finish: (string) -> ())
	local options = {}
	for _, t in Dialogue.FALSE do
		local ok = not used[t.id]
		if t.id == "force" then
			ok = ok and ctx.processing
		elseif t.id == "main" then
			ok = ok and ctx.powerOk
		elseif t.id == "door" then
			ok = ok and ctx.doorLatched
		end
		if ok then
			table.insert(options, t)
		end
	end
	if #options == 0 then
		table.clear(used)
		finish("skipped")
		return { cleanup = function() end }
	end
	local t = options[math.random(1, #options)]
	used[t.id] = true
	local id = GameState.bossMessage(t.text, "false", { "Comply", "Reject: Procedure " .. t.procedure })
	pending = { msgId = id, template = t, finish = finish }
	if not ctx.learned["false"] then
		GameState.notify(nil, "Kessler sent an instruction. Check it against Procedures.txt on the desktop before replying.", "info")
	end
	task.delay(cfg.replyWindow, function()
		if pending and pending.msgId == id then
			local m = GameState.findBoss(id)
			if m and not m.answered then
				m.answered = "(no reply)"
				GameState.markDirty()
			end
			pending = nil
			finish("ignored")
		end
	end)
	return {
		cleanup = function()
			pending = nil
		end,
	}
end

return FalseInstruction
