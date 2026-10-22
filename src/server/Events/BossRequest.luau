--!strict
-- BOSS REQUEST: a brief physical errand (trash, thermostat, printout).
-- Occasional by design so erasing drives stays central. A trash trip can
-- become the ALLEY ENCOUNTER: the figure appears at the alley end, gives a
-- head start, and chases the player back along the route they just walked.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Dialogue = require(ReplicatedStorage.Shared.Dialogue)
local Server = script.Parent.Parent
local Systems = Server.Systems
local Prompts = require(Server.Util.Prompts)
local Guard = require(Server.Util.Guard)
local GameState = require(Systems.GameState)
local MapBuilder = require(Systems.MapBuilder)
local Threat = require(Systems.Threat)
local Doors = require(Systems.Doors)

local cfg = Config.EVENTS.BossRequest

type Task = "trash" | "thermostat" | "printout"

local prompts: { [string]: ProximityPrompt } = {}
local current: {
	kind: Task,
	holder: Player?,
	item: BasePart?,
	done: boolean,
	chase: boolean,
	finish: ((string) -> ())?,
}? = nil
local alleyEncounters = 0

local BossRequest = {
	id = "BossRequest",
	urgent = false,
	mechanic = "boss",
	cooldown = cfg.cooldown,
	conflicts = { "FalseInstruction" },
}

local function dropItem()
	local c = current
	if not c then
		return
	end
	if c.item then
		c.item:Destroy()
		c.item = nil
	end
	if c.holder then
		if c.holder:GetAttribute("Carrying") == "TrashBag" or c.holder:GetAttribute("Carrying") == "Printout" then
			c.holder:SetAttribute("Carrying", nil)
		end
		c.holder = nil
	end
end

local function makeItem(player: Player, kind: Task): BasePart?
	local root = Guard.rootOf(player)
	if not root then
		return nil
	end
	local p = Instance.new("Part")
	p.Name = if kind == "trash" then "TrashBag" else "Printout"
	p.Size = if kind == "trash" then Vector3.new(1.5, 1.8, 1.3) else Vector3.new(1.1, 0.05, 1.4)
	p.Color = if kind == "trash" then Color3.fromRGB(30, 34, 30) else Color3.fromRGB(240, 238, 228)
	p.Material = if kind == "trash" then Enum.Material.Plastic else Enum.Material.SmoothPlastic
	p.CanCollide = false
	p.Massless = true
	p.CFrame = root.CFrame * CFrame.new(1.1, -0.6, -0.8)
	local w = Instance.new("WeldConstraint")
	w.Part0 = root
	w.Part1 = p
	w.Parent = p
	p.Parent = workspace
	return p
end

local function complete(outcome: string)
	local c = current
	if not c or c.done then
		return
	end
	c.done = true
	dropItem()
	for _, pr in prompts do
		pr.Enabled = false
	end
	GameState.setThreat("boss", nil)
	if outcome == "success" then
		GameState.bossMessage(Dialogue.REQUEST_DONE[math.random(1, #Dialogue.REQUEST_DONE)], "info")
	end
	local f = c.finish
	current = nil
	if f then
		f(outcome)
	end
end

local function alleyEligible(player: Player): boolean
	return GameState.data.erased >= 2 and not Threat.busy() and alleyEncounters < 2 and GameState.phase == "Work" and player.Parent ~= nil
end

function BossRequest.setup()
	local refs = MapBuilder.refs
	prompts.trash = Prompts.make(refs.kitchenTrash, { action = "Take trash bag", object = "Kitchen bin", hold = 0.6 })
	prompts.dumpster = Prompts.make(refs.dumpster, { action = "Throw bag away", object = "Dumpster", hold = 0.6 })
	prompts.thermostat = Prompts.make(refs.thermostat, { action = "Read thermostat", object = "Thermostat", hold = 1.0 })
	prompts.printer = Prompts.make(refs.printer, { action = "Take printout", object = "Printer", hold = 0.6 })
	prompts.outbox = Prompts.make(refs.outbox, { action = "Leave printout", object = "Out tray", hold = 0.4 })
	for _, pr in prompts do
		pr.Enabled = false
	end

	local function pick(player: Player, kind: Task)
		local c = current
		if not c or c.done or c.holder then
			return
		end
		if player:GetAttribute("Carrying") ~= nil then
			GameState.notify(player, "Your hands are full.", "bad")
			return
		end
		local item = makeItem(player, kind)
		if not item then
			return
		end
		c.holder = player
		c.item = item
		player:SetAttribute("Carrying", if kind == "trash" then "TrashBag" else "Printout")
		if kind == "trash" then
			prompts.trash.Enabled = false
			prompts.dumpster.Enabled = true
			GameState.setThreat("boss", "Errand: take the trash bag to the alley dumpster", false, "Alley")
		else
			prompts.printer.Enabled = false
			prompts.outbox.Enabled = true
			GameState.setThreat("boss", "Errand: put the printout in the OUT TRAY", false, "Workstation")
		end
	end

	prompts.trash.Triggered:Connect(function(player)
		if Prompts.valid(player, prompts.trash) then
			pick(player, "trash")
		end
	end)
	prompts.printer.Triggered:Connect(function(player)
		if Prompts.valid(player, prompts.printer) then
			pick(player, "printout")
		end
	end)
	prompts.dumpster.Triggered:Connect(function(player)
		local c = current
		if not c or c.holder ~= player or not Prompts.valid(player, prompts.dumpster) then
			return
		end
		GameState.fx("TrashThrown", nil)
		if alleyEligible(player) then
			-- the alley encounter: same route back, head start, door is the goal
			alleyEncounters += 1
			c.chase = true
			dropItem()
			prompts.dumpster.Enabled = false
			local first = alleyEncounters == 1
			GameState.notify(player, "Someone is standing at the end of the alley...", "bad")
			Threat.chase(player, first, function(caught)
				if Doors.state() == "Latched" then
					Doors.set("Ajar")
				end
				complete(if caught then "failure" else "success")
			end)
		else
			complete("success")
		end
	end)
	prompts.outbox.Triggered:Connect(function(player)
		local c = current
		if c and c.holder == player and Prompts.valid(player, prompts.outbox) then
			complete("success")
		end
	end)
	prompts.thermostat.Triggered:Connect(function(player)
		local c = current
		if c and c.kind == "thermostat" and Prompts.valid(player, prompts.thermostat) then
			GameState.notify(nil, player.DisplayName .. " read the thermostat: 59°F. The hall is colder than it should be.", "info")
			complete("success")
		end
	end)

	-- holder lost (left, died, caught): the item goes back where it came from
	local function lost(player: Player)
		local c = current
		if c and c.holder == player and not c.chase then
			dropItem()
			if c.kind == "trash" then
				prompts.trash.Enabled = true
				prompts.dumpster.Enabled = false
			elseif c.kind == "printout" then
				prompts.printer.Enabled = true
				prompts.outbox.Enabled = false
			end
		end
	end
	Players.PlayerRemoving:Connect(lost)
	task.spawn(function()
		while true do
			task.wait(1)
			local c = current
			if c and c.holder and (not Guard.alive(c.holder) or c.holder:GetAttribute("Downed") == true) then
				lost(c.holder)
			end
		end
	end)
	GameState.RoundReset:Connect(function()
		alleyEncounters = 0
	end)
end

function BossRequest.eligible(ctx: any): boolean
	return ctx.phase == "Work" and current == nil and ctx.erased >= cfg.minErased
end

function BossRequest.weight(ctx: any): number
	-- requests are occasional; more likely when nobody is at the PC
	return cfg.weight * (if ctx.operator then 0.7 else 1.2)
end

function BossRequest.start(ctx: any, finish: (string) -> ())
	local kinds: { Task } = { "thermostat", "printout", "trash" }
	if ctx.erased >= 2 then
		table.insert(kinds, "trash") -- trash trips get likelier once the alley matters
	end
	local kind: Task = kinds[math.random(1, #kinds)]
	current = { kind = kind, holder = nil, item = nil, done = false, chase = false, finish = finish }
	GameState.bossMessage(Dialogue.BOSS_REQUESTS[kind], "request")
	if kind == "trash" then
		prompts.trash.Enabled = true
		GameState.setThreat("boss", "Errand: take out the kitchen trash", false, "Kitchenette")
	elseif kind == "printout" then
		prompts.printer.Enabled = true
		MapBuilder.refs.printerLed.Color = Color3.fromRGB(80, 255, 120)
		GameState.fx("PrinterWake", nil)
		GameState.setThreat("boss", "Errand: bring the printout to the OUT TRAY", false, "Office")
	else
		prompts.thermostat.Enabled = true
		GameState.setThreat("boss", "Errand: check the thermostat", false, "Utility hall")
	end
	local myCurrent = current
	task.delay(cfg.timeout, function()
		if current == myCurrent and current and not current.done and not current.chase then
			GameState.bossMessage(Dialogue.REQUEST_LATE, "info")
			complete("timeout")
		end
	end)
	return {
		urgentNow = function()
			local c = current
			return c ~= nil and c.chase
		end,
		cleanup = function()
			local c = current
			if c then
				c.finish = nil
				if c.chase and Threat.busy() then
					Threat.despawn()
				end
				complete("cancelled")
			end
			MapBuilder.refs.printerLed.Color = Color3.fromRGB(40, 60, 40)
		end,
	}
end

return BossRequest
