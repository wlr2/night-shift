--!strict
-- DOOR UNLATCHES: chime + draft + red indicator. Someone must close and latch
-- the rear door before the figure arrives. If the grace runs out the figure
-- walks up the alley (visible, audible) and can still be shut out until it
-- reaches the doorway. Otherwise it comes inside for a limited hunt.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Systems = script.Parent.Parent.Systems
local GameState = require(Systems.GameState)
local Doors = require(Systems.Doors)
local Threat = require(Systems.Threat)

local cfg = Config.EVENTS.DoorUnlatch

local DoorUnlatch = {
	id = "DoorUnlatch",
	urgent = true,
	mechanic = "door",
	cooldown = cfg.cooldown,
	conflicts = { "BossRequest" },
}

function DoorUnlatch.eligible(ctx: any): boolean
	return ctx.doorLatched and not ctx.threatBusy and ctx.erased >= cfg.minErased and ctx.phase ~= "ClockOut"
end

function DoorUnlatch.weight(ctx: any): number
	return cfg.weight * (if ctx.tier == "early" then 0.8 else 1)
end

function DoorUnlatch.start(ctx: any, finish: (string) -> ())
	local first = not ctx.learned.door
	local alive = true
	local approaching = false
	local grace = if first then cfg.graceFirst else (cfg.grace :: any)[ctx.tier]
	if not ctx.opts.watch then
		Doors.set("Ajar")
		GameState.notify(nil, if first
			then "The rear door just unlatched. Close and LATCH it (utility hall) before someone comes in."
			else "Rear door unlatched.", "bad")
	else
		grace = math.max(4, grace - Doors.unsecuredFor())
		GameState.notify(nil, "The rear door has been left open. Latch it!", "bad")
	end
	local conn = Doors.Changed:Connect(function(new)
		if new == "Latched" and alive and not approaching then
			alive = false
			GameState.notify(nil, "Rear door secured.", "good")
			finish("success")
		end
	end)
	task.delay(grace, function()
		if not alive then
			return
		end
		if Doors.state() == "Latched" then
			alive = false
			finish("success")
			return
		end
		approaching = true
		Threat.approach({
			onRepelled = function()
				GameState.notify(nil, "It stood at the door... then walked away.", "good")
			end,
			onEntered = function()
				GameState.notify(nil, "Something came in through the rear door. Keep away from it!", "bad")
			end,
			onDone = function()
				if alive then
					alive = false
					finish("resolved")
				end
			end,
		})
	end)
	return {
		cleanup = function()
			alive = false
			conn:Disconnect()
			if approaching and Threat.busy() then
				Threat.despawn()
			end
		end,
	}
end

return DoorUnlatch
