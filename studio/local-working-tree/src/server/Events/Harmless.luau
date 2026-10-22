--!strict
-- HARMLESS DISTURBANCE: unease without punishment. A neighbouring monitor
-- wakes up, the printer chatters, a chair shifts, footsteps stop outside, the
-- phone rings once... Later in the shift: a glimpse of someone outside.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Dialogue = require(ReplicatedStorage.Shared.Dialogue)
local Systems = script.Parent.Parent.Systems
local GameState = require(Systems.GameState)
local MapBuilder = require(Systems.MapBuilder)
local Threat = require(Systems.Threat)

local cfg = Config.EVENTS.Harmless

type Variant = { id: string, minErased: number, run: (ctx: any) -> () }

local lastVariant: string? = nil
local chairHome: CFrame? = nil

local VARIANTS: { Variant } = {
	{
		id = "monitor",
		minErased = 0,
		run = function(_ctx)
			local screens = MapBuilder.refs.sourceScreens
			local i = math.random(1, #screens)
			local texts = Dialogue.HARMLESS.monitor
			GameState.fx("MonitorWake", { desk = i, text = texts[math.random(1, #texts)], seconds = 6 })
		end,
	},
	{
		id = "printer",
		minErased = 0,
		run = function(_ctx)
			GameState.fx("PrinterWake", nil)
		end,
	},
	{
		id = "chair",
		minErased = 1,
		run = function(_ctx)
			local chair = MapBuilder.refs.shiftChair
			chairHome = chairHome or chair.CFrame
			local home = chairHome :: CFrame
			chair.CFrame = home * CFrame.new(math.random(-8, 8) / 10, 0, math.random(-8, 8) / 10) * CFrame.Angles(0, math.rad(math.random(-60, 60)), 0)
			GameState.fx("ChairShift", { pos = chair.Position })
		end,
	},
	{
		id = "footsteps",
		minErased = 1,
		run = function(_ctx)
			GameState.fx("FootstepsStop", { pos = Vector3.new(math.random(-14, 6), 4, -18) })
		end,
	},
	{
		id = "phone",
		minErased = 0,
		run = function(_ctx)
			GameState.fx("PhoneRing", { pos = Vector3.new(21.1, 3.2, -12.4) })
		end,
	},
	{
		id = "flicker",
		minErased = 0,
		run = function(_ctx)
			GameState.fx("LightFlicker", { seconds = 1.6 })
		end,
	},
	{
		id = "knock",
		minErased = 2,
		run = function(_ctx)
			GameState.fx("FrontKnock", nil)
		end,
	},
	{
		id = "figure",
		minErased = 3,
		run = function(_ctx)
			if not Threat.busy() then
				Threat.peek(if math.random() < 0.5 then "window" else "alley", 3.5)
			end
		end,
	},
	{
		id = "crew",
		minErased = 5,
		run = function(_ctx)
			for _, fig in MapBuilder.refs.crewFigures do
				fig:SetAttribute("ArtHidden", false)
			end
			GameState.fx("CrewSeen", nil)
			task.delay(4, function()
				for _, fig in MapBuilder.refs.crewFigures do
					fig:SetAttribute("ArtHidden", true)
				end
			end)
		end,
	},
}

local Harmless = {
	id = "Harmless",
	urgent = false,
	mechanic = nil,
	cooldown = cfg.cooldown,
	conflicts = {},
}

function Harmless.setup()
	GameState.RoundReset:Connect(function()
		if chairHome then
			MapBuilder.refs.shiftChair.CFrame = chairHome
		end
		for _, fig in MapBuilder.refs.crewFigures do
			fig:SetAttribute("ArtHidden", true)
		end
	end)
end

function Harmless.eligible(_ctx: any): boolean
	return true
end

function Harmless.weight(ctx: any): number
	-- the cosy early shift leans on small oddities
	return cfg.weight * (if ctx.tier == "early" then 1.3 else 1)
end

function Harmless.start(ctx: any, finish: (string) -> ())
	local pool = {}
	for _, v in VARIANTS do
		if ctx.erased >= v.minErased and v.id ~= lastVariant then
			table.insert(pool, v)
		end
	end
	local v = pool[math.random(1, #pool)]
	lastVariant = v.id
	v.run(ctx)
	task.delay(2, function()
		finish(v.id)
	end)
	return { cleanup = function() end }
end

return Harmless
