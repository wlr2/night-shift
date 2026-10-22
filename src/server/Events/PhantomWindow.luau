--!strict
-- PHANTOM DESKTOP WINDOW: a strange window covers part of the job. Learned
-- cue: its title bar is red-brown, not blue, and its real close button is on
-- the LEFT. The fake OK button spawns one more copy. Progress is never lost;
-- the window fades by itself after a while.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Systems = script.Parent.Parent.Systems
local Workstation = require(Systems.Workstation)

local cfg = Config.EVENTS.PhantomWindow

local current: { id: number, x: number, y: number, first: boolean }? = nil
local extraSpawned = 0
local nextId = 1
local onClosed: ((string) -> ())? = nil

local PhantomWindow = {
	id = "PhantomWindow",
	urgent = false,
	mechanic = "phantom",
	cooldown = cfg.cooldown,
	conflicts = { "PowerFailure" },
}

local function show(first: boolean)
	current = { id = nextId, x = 0.18 + math.random() * 0.4, y = 0.14 + math.random() * 0.35, first = first }
	nextId += 1
	Workstation.setPhantom(current)
end

function PhantomWindow.setup()
	Workstation.registerCommand("phantom", function(_player, a, b)
		local cur = current
		if not cur or a ~= cur.id then
			return nil
		end
		if b == "close" then
			current = nil
			Workstation.setPhantom(nil)
			if onClosed then
				onClosed("success")
			end
			return "Unknown window closed.", "good"
		elseif b == "ok" then
			if extraSpawned < 1 then
				extraSpawned += 1
				show(false)
				return "That was not a real dialog. Look for the odd title bar and the X on the LEFT.", "bad"
			end
			return "Nothing happens.", "bad"
		end
		return nil
	end)
end

function PhantomWindow.eligible(ctx: any): boolean
	return ctx.operator ~= nil and ctx.processing and ctx.powerOk and ctx.erased >= cfg.minErased and ctx.phase == "Work"
end

function PhantomWindow.weight(ctx: any): number
	return cfg.weight * (if ctx.tier == "late" then 1.2 else 1)
end

function PhantomWindow.start(ctx: any, finish: (string) -> ())
	extraSpawned = 0
	local alive = true
	onClosed = function(outcome)
		if alive then
			alive = false
			onClosed = nil
			finish(outcome)
		end
	end
	show(not ctx.learned.phantom)
	task.delay(cfg.lifetime, function()
		if alive then
			alive = false
			onClosed = nil
			current = nil
			Workstation.setPhantom(nil)
			finish("faded")
		end
	end)
	return {
		cleanup = function()
			alive = false
			onClosed = nil
			current = nil
			Workstation.setPhantom(nil)
		end,
	}
end

return PhantomWindow
