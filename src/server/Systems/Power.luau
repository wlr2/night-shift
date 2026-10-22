--!strict
-- Breakers and building power. MAIN feeds everything; LIGHTS feeds the
-- office lighting; WORKSTATION feeds the corner PC. Tripped breakers are
-- reset at the clearly labelled panel in the utility hall.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Server = script.Parent.Parent
local Prompts = require(Server.Util.Prompts)
local GameState = require(script.Parent.GameState)
local MapBuilder = require(script.Parent.MapBuilder)

local Power = {}

export type BreakerId = "MAIN" | "LIGHTS" | "WORKSTATION"

local breakers: { [string]: boolean } = { MAIN = true, LIGHTS = true, WORKSTATION = true }
local warning = false
local prompts: { [string]: ProximityPrompt } = {}
-- prompt object line per switch, matching the tags on the panel
local BREAKER_NAMES = { MAIN = "Main", LIGHTS = "Office lights", WORKSTATION = "Workstation" }
local tripToken = 0 -- bumped by resetAll so a pending warned trip is cancelled

Power.Changed = Signal.new() :: Signal.Signal<>
Power.BreakerReset = Signal.new() :: Signal.Signal<string, Player?>

function Power.lightsOn(): boolean
	return breakers.MAIN and breakers.LIGHTS
end

function Power.workstationOn(): boolean
	return breakers.MAIN and breakers.WORKSTATION
end

function Power.isTripped(id: string): boolean
	return breakers[id] == false
end

function Power.anyTripped(): boolean
	return not (breakers.MAIN and breakers.LIGHTS and breakers.WORKSTATION)
end

local function apply()
	local refs = MapBuilder.refs
	local lights = Power.lightsOn()
	local ws = Power.workstationOn()
	for _, groupName in { "main", "kitchen", "lobby", "hall", "lamps" } do
		local group: { Light } = refs.lights[groupName] or {}
		for _, l in group do
			l.Enabled = lights
		end
		local fixtures: { BasePart } = refs.fixtures[groupName] or {}
		for _, f in fixtures do
			f.Material = if lights then Enum.Material.Neon else Enum.Material.SmoothPlastic
			f.Color = if lights then Color3.fromRGB(226, 240, 255) else Color3.fromRGB(70, 72, 76)
		end
	end
	refs.workstationLamp.Enabled = ws
	for _, l in refs.emergencyLights do
		(l :: PointLight).Brightness = if lights then 0 else 0.9
	end
	refs.monitorScreen.Material = if ws then Enum.Material.Neon else Enum.Material.SmoothPlastic
	refs.monitorScreen.Color = if ws then Color3.fromRGB(16, 32, 60) else Color3.fromRGB(8, 8, 10)
	for id, ok in breakers do
		local lamp = refs.breakerLamps[id]
		if lamp then
			lamp.Color = if ok then Color3.fromRGB(60, 255, 90) else Color3.fromRGB(255, 50, 40)
		end
		local sw = refs.breakerSwitches[id]
		if sw then
			sw.Color = if ok then Color3.fromRGB(40, 40, 40) else Color3.fromRGB(150, 30, 30)
			sw:SetAttribute("Tripped", not ok)
		end
		local prompt = prompts[id]
		if prompt then
			prompt.Enabled = not ok
		end
	end
	workspace:SetAttribute("LightsOn", lights)
	workspace:SetAttribute("WorkstationPower", ws)
	if Power.anyTripped() then
		local where = {}
		for _, id in { "MAIN", "LIGHTS", "WORKSTATION" } do
			if not breakers[id] then
				table.insert(where, id)
			end
		end
		GameState.setThreat("power", "Breaker tripped: " .. table.concat(where, " + "), true, "Utility hall")
	else
		GameState.setThreat("power", nil)
	end
	GameState.markDirty()
	Power.Changed:Fire()
end

-- Flicker warning (cosmetic on clients), then trip the listed breakers.
function Power.warnThenTrip(ids: { string }, warningSeconds: number, onTripped: (() -> ())?)
	warning = true
	tripToken += 1
	local my = tripToken
	GameState.markDirty()
	GameState.fx("PowerWarning", { seconds = warningSeconds })
	task.delay(warningSeconds, function()
		if my ~= tripToken then
			return
		end
		warning = false
		Power.trip(ids)
		if onTripped then
			onTripped()
		end
	end)
end

function Power.trip(ids: { string })
	for _, id in ids do
		if breakers[id] ~= nil then
			breakers[id] = false
		end
	end
	GameState.fx("PowerOff", { ids = ids })
	apply()
end

function Power.reset(id: string, by: Player?)
	if breakers[id] == false then
		breakers[id] = true
		GameState.fx("BreakerReset", { id = id })
		apply()
		Power.BreakerReset:Fire(id, by)
	end
end

function Power.resetAll()
	tripToken += 1
	warning = false
	for id in breakers do
		breakers[id] = true
	end
	apply()
end

function Power.snapshot()
	return {
		main = breakers.MAIN,
		lights = Power.lightsOn(),
		workstation = Power.workstationOn(),
		warning = warning,
	}
end

function Power.init()
	GameState.providers.power = Power.snapshot
	for id, sw in MapBuilder.refs.breakerSwitches do
		local prompt = Prompts.make(sw, {
			action = "Reset breaker",
			object = BREAKER_NAMES[id] or id,
			hold = 0.8,
			distance = 8,
		})
		prompt.Enabled = false
		prompts[id] = prompt
		prompt.Triggered:Connect(function(player)
			if not Prompts.valid(player, prompt) then
				return
			end
			Power.reset(id, player)
		end)
	end
	GameState.RoundReset:Connect(Power.resetAll)
	apply()
end

return Power
