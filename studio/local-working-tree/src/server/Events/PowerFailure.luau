--!strict
-- POWER FAILURE: lights flicker (warning), then breakers trip. Desktop work
-- pauses safely; the puzzle state is untouched. Someone resets the labelled
-- breakers in the utility hall. Later in the shift two breakers may trip.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Systems = script.Parent.Parent.Systems
local GameState = require(Systems.GameState)
local Power = require(Systems.Power)
local Threat = require(Systems.Threat)

local cfg = Config.EVENTS.PowerFailure

local PowerFailure = {
	id = "PowerFailure",
	urgent = true,
	mechanic = "power",
	cooldown = cfg.cooldown,
	conflicts = { "PhantomWindow" },
}

function PowerFailure.eligible(ctx: any): boolean
	local m = Threat.mode()
	return ctx.powerOk and ctx.erased >= cfg.minErased and ctx.phase ~= "ClockOut" and m ~= "hunt" and m ~= "approach"
end

function PowerFailure.weight(ctx: any): number
	-- more likely while someone is actually working at the PC
	return cfg.weight * (if ctx.processing then 1.3 else 0.7)
end

function PowerFailure.start(ctx: any, finish: (string) -> ())
	local first = not ctx.learned.power
	local ids = { "MAIN" }
	if not first and not ctx.solo and math.random() < (cfg.multiTripChance :: any)[ctx.tier] then
		ids = if math.random() < 0.5 then { "MAIN", "WORKSTATION" } else { "LIGHTS", "WORKSTATION" }
	elseif not first and ctx.tier ~= "early" and math.random() < 0.35 then
		ids = { if math.random() < 0.5 then "LIGHTS" else "WORKSTATION" }
	end
	local alive = true
	local tripped = false
	local conn = Power.Changed:Connect(function()
		if alive and tripped and not Power.anyTripped() then
			alive = false
			GameState.notify(nil, "Power restored. Work resumes where it stopped.", "good")
			finish("success")
		end
	end)
	Power.warnThenTrip(ids, if first then cfg.warningSeconds + 2 else cfg.warningSeconds, function()
		tripped = true
		if not alive then
			return
		end
		GameState.notify(nil, if first
			then "Power failure! Reset the tripped breaker(s) at the panel in the UTILITY HALL. The PC keeps your progress."
			else "Breaker tripped: " .. table.concat(ids, " + "), "bad")
	end)
	task.delay(90, function()
		if alive and Power.anyTripped() then
			GameState.bossMessage("Why is the building dark? The breaker panel is in the utility hall.", "info")
		end
	end)
	return {
		cleanup = function()
			alive = false
			conn:Disconnect()
		end,
	}
end

return PowerFailure
