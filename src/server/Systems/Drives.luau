--!strict
-- Hard drives. The server is the only authority on each drive's state:
--   Installed -> Carried -> Staged -> Docked -> Processing -> Erased
-- Every transition goes through `transition()`, which checks the current
-- state, so duplicate pickups, double owners, removing an in-use drive and
-- repeated completion rewards are impossible by construction.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Layout = require(ReplicatedStorage.Shared.Layout)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Types = require(ReplicatedStorage.Shared.Types)
local Server = script.Parent.Parent
local Prompts = require(Server.Util.Prompts)
local Guard = require(Server.Util.Guard)
local Minigames = require(Server.Minigames)
local GameState = require(script.Parent.GameState)
local MapBuilder = require(script.Parent.MapBuilder)

type DriveState = Types.DriveState

export type Drive = {
	id: string,
	name: string,
	color: Color3,
	desk: number,
	state: DriveState,
	carrier: Player?,
	slot: number?,
	game: string,
	job: Minigames.Job?,
	pcOff: boolean,
	part: BasePart,
	labelText: TextLabel,
	led: BasePart,
	prompt: ProximityPrompt,
}

local Drives = {}

Drives.list = {} :: { Drive }
Drives.byId = {} :: { [string]: Drive }
Drives.Erased = Signal.new() :: Signal.Signal<Drive, number>
Drives.StateChanged = Signal.new() :: Signal.Signal<Drive, DriveState, DriveState>
Drives.Docked = Signal.new() :: Signal.Signal<Drive>

local pcPrompts: { ProximityPrompt } = {}
local rackPrompt: ProximityPrompt
local dockPrompt: ProximityPrompt
local roundRng = Random.new()

local function setCarrying(player: Player, what: string?)
	player:SetAttribute("Carrying", what)
end

local function carrying(player: Player): string?
	local v = player:GetAttribute("Carrying")
	return if typeof(v) == "string" then v else nil
end
Drives.carrying = carrying

function Drives.dockDrive(): Drive?
	for _, d in Drives.list do
		if d.state == "Docked" or d.state == "Processing" then
			return d
		end
	end
	return nil
end

local function freeSlot(kind: "staging" | "erased"): number
	local used: { [number]: boolean } = {}
	for _, d in Drives.list do
		if d.slot and ((kind == "staging" and d.state == "Staged") or (kind == "erased" and d.state == "Erased")) then
			used[d.slot] = true
		end
	end
	for i = 1, 6 do
		if not used[i] then
			return i
		end
	end
	return 1
end

local function detachFromCarrier(d: Drive)
	for _, c in d.part:GetChildren() do
		if c:IsA("WeldConstraint") or c:IsA("Weld") then
			c:Destroy()
		end
	end
	d.part.Anchored = true
	if d.carrier then
		setCarrying(d.carrier, nil)
	end
	d.carrier = nil
end

local function refreshVisual(d: Drive)
	local refs = MapBuilder.refs
	if d.state == "Installed" then
		d.part.Transparency = 0
		d.part.CFrame = refs.drivePlace[d.desk]
		refs.sourceLeds[d.desk].Color = if d.pcOff then Color3.fromRGB(255, 170, 40) else Color3.fromRGB(80, 255, 120)
	else
		refs.sourceLeds[d.desk].Color = Color3.fromRGB(30, 30, 30)
	end
	if d.state == "Staged" and d.slot then
		d.part.CFrame = refs.stagingSlots[d.slot]
	elseif d.state == "Erased" and d.slot then
		d.part.CFrame = refs.erasedSlots[d.slot]
	elseif d.state == "Docked" or d.state == "Processing" then
		d.part.CFrame = refs.dock.CFrame * CFrame.new(0, 0.2, -0.55) * CFrame.Angles(math.rad(90), 0, 0)
	end
	local erased = d.state == "Erased"
	d.labelText.Text = if erased then d.id .. "\nERASED" else d.id .. "\n" .. d.name
	d.labelText.BackgroundColor3 = if erased then Color3.fromRGB(40, 150, 70) else d.color
	d.led.Color = if erased
		then Color3.fromRGB(60, 255, 90)
		elseif d.state == "Processing" then Color3.fromRGB(255, 190, 40)
		else Color3.fromRGB(255, 60, 50)
	d.part:SetAttribute("State", d.state)
	-- prompt on the drive itself: only for taking a staged drive
	d.prompt.Enabled = d.state == "Staged"
end

local function refreshPrompts()
	for i, prompt in pcPrompts do
		local d: Drive? = nil
		for _, x in Drives.list do
			if x.desk == i then
				d = x
			end
		end
		if d and d.state == "Installed" then
			prompt.Enabled = true
			prompt.ActionText = if d.pcOff then "Remove drive" else "Shut down PC"
			prompt.ObjectText = d.id
			prompt.HoldDuration = if d.pcOff then 1.0 else 0.8
		else
			prompt.Enabled = false
		end
	end
	local docked = Drives.dockDrive()
	if not docked then
		dockPrompt.Enabled = true
		dockPrompt.ActionText = "Connect drive"
		dockPrompt.ObjectText = "Workstation dock"
	elseif docked.state == "Docked" then
		dockPrompt.Enabled = true
		dockPrompt.ActionText = "Eject drive"
		dockPrompt.ObjectText = docked.id
	else
		dockPrompt.Enabled = false
	end
	rackPrompt.Enabled = true
end

local function transition(d: Drive, from: { DriveState }, to: DriveState): boolean
	if not table.find(from, d.state) then
		return false
	end
	local old: DriveState = d.state :: DriveState
	d.state = to
	refreshVisual(d)
	refreshPrompts()
	GameState.markDirty()
	Drives.StateChanged:Fire(d, old, to)
	return true
end

local function attachTo(d: Drive, player: Player): boolean
	local root = Guard.rootOf(player)
	if not root then
		return false
	end
	d.part.Anchored = false
	d.part.CFrame = root.CFrame * CFrame.new(0.6, -0.3, -1.3) * CFrame.Angles(math.rad(-20), 0, 0)
	local w = Instance.new("WeldConstraint")
	w.Part0 = root
	w.Part1 = d.part
	w.Parent = d.part
	d.carrier = player
	setCarrying(player, d.id)
	pcall(function()
		d.part:SetNetworkOwner(player)
	end)
	return true
end

-- Return a drive to the recovery rack (carrier left, died, downed or the
-- drive fell out of the map). Never loses a drive or its job progress.
function Drives.recover(d: Drive, reason: string?)
	if d.state ~= "Carried" then
		return
	end
	detachFromCarrier(d)
	d.slot = freeSlot("staging")
	transition(d, { "Carried" }, "Staged")
	GameState.notify(nil, d.id .. " returned to the drive rack" .. (if reason then " (" .. reason .. ")" else "") .. ".", "info")
end

function Drives.recoverFor(player: Player, reason: string?)
	for _, d in Drives.list do
		if d.carrier == player then
			Drives.recover(d, reason)
		end
	end
end

function Drives.pickup(player: Player, d: Drive): boolean
	if carrying(player) then
		GameState.notify(player, "Your hands are full.", "bad")
		return false
	end
	if d.state == "Installed" then
		if not d.pcOff then
			return false
		end
	elseif d.state ~= "Staged" then
		return false
	end
	local from: DriveState = d.state :: DriveState
	if not transition(d, { from }, "Carried") then
		return false
	end
	if not attachTo(d, player) then
		-- could not attach (no character): roll back to a safe state
		d.state = from
		refreshVisual(d)
		refreshPrompts()
		return false
	end
	d.slot = nil
	return true
end

function Drives.stage(player: Player): boolean
	local id = carrying(player)
	local d = id and Drives.byId[id]
	if not d or d.carrier ~= player or d.state ~= "Carried" then
		return false
	end
	detachFromCarrier(d)
	d.slot = freeSlot("staging")
	return transition(d, { "Carried" }, "Staged")
end

function Drives.dock(player: Player): boolean
	local id = carrying(player)
	local d = id and Drives.byId[id]
	if not d or d.carrier ~= player or d.state ~= "Carried" then
		return false
	end
	if Drives.dockDrive() then
		GameState.notify(player, "The dock is busy. Stage the drive on the rack.", "bad")
		return false
	end
	detachFromCarrier(d)
	if transition(d, { "Carried" }, "Docked") then
		GameState.fx("DriveDocked", { id = d.id })
		Drives.Docked:Fire(d)
		return true
	end
	return false
end

function Drives.eject(player: Player): boolean
	local d = Drives.dockDrive()
	if not d or d.state ~= "Docked" or carrying(player) then
		return false
	end
	if not transition(d, { "Docked" }, "Carried") then
		return false
	end
	if not attachTo(d, player) then
		d.state = "Docked"
		refreshVisual(d)
		refreshPrompts()
		return false
	end
	return true
end

-- Called by the workstation when the operator starts/resumes SecureErase.
function Drives.beginProcessing(d: Drive): Minigames.Job?
	if d.state == "Processing" then
		return d.job
	end
	if d.state ~= "Docked" then
		return nil
	end
	if not d.job then
		d.job = Minigames.newJob(d.game, GameState.isSolo(), roundRng:NextInteger(1, 2 ^ 30))
	end
	transition(d, { "Docked" }, "Processing")
	return d.job
end

-- Only reachable when the minigame logic itself reports completion.
function Drives.markErased(d: Drive): boolean
	if not d.job or not d.job.complete then
		return false
	end
	if d.state ~= "Processing" then
		return false
	end
	d.slot = freeSlot("erased")
	if not transition(d, { "Processing" }, "Erased") then
		return false
	end
	local count = 0
	for _, x in Drives.list do
		if x.state == "Erased" then
			count += 1
		end
	end
	GameState.data.erased = count
	GameState.markDirty()
	GameState.fx("DriveErased", { id = d.id, count = count })
	Drives.Erased:Fire(d, count)
	return true
end

function Drives.erasedCount(): number
	local n = 0
	for _, d in Drives.list do
		if d.state == "Erased" then
			n += 1
		end
	end
	return n
end

function Drives.snapshot(): { Types.DriveSnapshot }
	local out = {}
	for _, d in Drives.list do
		local job = d.job
		local title: string? = nil
		local g = Minigames.get(d.game)
		if g then
			title = g.title
		end
		table.insert(out, {
			id = d.id,
			name = d.name,
			state = d.state,
			game = d.game,
			gameTitle = title,
			progress = if job then Minigames.progress(job) elseif d.state == "Erased" then 1 else 0,
			stage = if job then job.state.stage else 0,
			stages = if job then job.state.stages else 0,
			carrier = if d.carrier then d.carrier.DisplayName else nil,
			desk = d.desk,
		})
	end
	return out
end

-- Checkpoint support --------------------------------------------------------

export type SavedDrive = { id: string, state: DriveState, slot: number?, pcOff: boolean, job: Minigames.Job?, game: string }

function Drives.serialize(): { SavedDrive }
	local out = {}
	for _, d in Drives.list do
		local state: DriveState = d.state :: DriveState
		local slot = d.slot
		if state == "Carried" then
			state = "Staged"
			slot = nil
		end
		table.insert(out, {
			id = d.id,
			state = state,
			slot = slot,
			pcOff = d.pcOff,
			job = if d.job then Minigames.deepCopy(d.job) else nil,
			game = d.game,
		})
	end
	return out
end

function Drives.restore(saved: { SavedDrive })
	for _, s in saved do
		local d = Drives.byId[s.id]
		if d then
			detachFromCarrier(d)
			d.state = s.state
			d.pcOff = s.pcOff
			d.game = s.game
			d.job = if s.job then Minigames.deepCopy(s.job) else nil
			if d.job then
				d.job.transitionUntil = 0
			end
			d.slot = s.slot
		end
	end
	for _, d in Drives.list do
		if d.state == "Staged" and not d.slot then
			d.slot = freeSlot("staging")
		end
		refreshVisual(d)
	end
	GameState.data.erased = Drives.erasedCount()
	refreshPrompts()
	GameState.markDirty()
end

local function resetRound()
	local order = Minigames.assign(roundRng)
	for i, d in Drives.list do
		detachFromCarrier(d)
		d.state = "Installed"
		d.pcOff = false
		d.slot = nil
		d.job = nil
		d.game = order[i]
		refreshVisual(d)
	end
	for _, p in Players:GetPlayers() do
		if Drives.byId[carrying(p) or ""] then
			setCarrying(p, nil)
		end
	end
	GameState.data.erased = 0
	refreshPrompts()
	GameState.markDirty()
end

-- Construction ---------------------------------------------------------------

local function makeDrivePart(def: { id: string, name: string, color: Color3 }): (BasePart, TextLabel, BasePart)
	local p = Instance.new("Part")
	p.Name = "Drive_" .. def.id
	p.Size = Vector3.new(1.05, 0.32, 1.45)
	p.Color = Color3.fromRGB(150, 154, 160)
	p.Material = Enum.Material.Metal
	p.Anchored = true
	p.CanCollide = false
	p.Massless = true
	p:SetAttribute("DriveId", def.id)
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Top
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 60
	sg.LightInfluence = 0.5
	sg.Parent = p
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(0.86, 0.6)
	t.Position = UDim2.fromScale(0.07, 0.2)
	t.BackgroundColor3 = def.color
	t.TextColor3 = Color3.fromRGB(20, 20, 20)
	t.Font = Enum.Font.Arcade
	t.TextScaled = true
	t.Text = def.id
	t.Parent = sg
	local led = Instance.new("Part")
	led.Name = "Led"
	led.Size = Vector3.new(0.1, 0.1, 0.1)
	led.Material = Enum.Material.Neon
	led.Color = Color3.fromRGB(255, 60, 50)
	led.CanCollide = false
	led.Massless = true
	led.Anchored = false
	led.CFrame = p.CFrame * CFrame.new(0.4, 0.16, -0.6)
	local w = Instance.new("WeldConstraint")
	w.Part0 = p
	w.Part1 = led
	w.Parent = led
	led.Parent = p
	return p, t, led
end

function Drives.init()
	local refs = MapBuilder.refs
	local folder = Instance.new("Folder")
	folder.Name = "Drives"
	folder.Parent = refs.map
	local order = Minigames.assign(roundRng)
	for i, def in Config.DRIVES do
		local p, t, led = makeDrivePart(def)
		local prompt = Prompts.make(p, { action = "Take drive", object = def.id, distance = 7 })
		local d: Drive = {
			id = def.id,
			name = def.name,
			color = def.color,
			desk = i,
			state = "Installed",
			carrier = nil,
			slot = nil,
			game = order[i],
			job = nil,
			pcOff = false,
			part = p,
			labelText = t,
			led = led,
			prompt = prompt,
		}
		p.Parent = folder
		table.insert(Drives.list, d)
		Drives.byId[d.id] = d
		prompt.Triggered:Connect(function(player)
			if Prompts.valid(player, prompt, "drive") then
				Drives.pickup(player, d)
			end
		end)
	end

	for i, pc in refs.sourcePCs do
		local prompt = Prompts.make(pc, { action = "Shut down PC", object = "", hold = 0.8, distance = 8 })
		pcPrompts[i] = prompt
		prompt.Triggered:Connect(function(player)
			if not Prompts.valid(player, prompt, "pc") then
				return
			end
			local d: Drive? = nil
			for _, x in Drives.list do
				if x.desk == i then
					d = x
				end
			end
			if not d or d.state ~= "Installed" then
				return
			end
			if not d.pcOff then
				d.pcOff = true
				refreshVisual(d)
				refreshPrompts()
				GameState.fx("PcShutdown", { desk = i })
			else
				Drives.pickup(player, d)
			end
		end)
	end

	-- placing a drive is always F / R1; taking is E / X (no competing prompts)
	rackPrompt = Prompts.make(refs.recoveryRack, { action = "Stage drive", object = "Drive rack", distance = 8, key = Enum.KeyCode.F, gamepad = Enum.KeyCode.ButtonR1 })
	rackPrompt.Triggered:Connect(function(player)
		if Prompts.valid(player, rackPrompt, "rack") then
			if not Drives.byId[carrying(player) or ""] then
				GameState.notify(player, "Carry a drive here to stage it for the workstation.", "info")
				return
			end
			Drives.stage(player)
		end
	end)

	-- own key (F / R1) so it never competes with the chair prompt (E) at the cramped desk
	dockPrompt = Prompts.make(refs.dock, { action = "Connect drive", object = "Workstation dock", distance = 8, hold = 0.5, key = Enum.KeyCode.F, gamepad = Enum.KeyCode.ButtonR1 })
	dockPrompt.Triggered:Connect(function(player)
		if not Prompts.valid(player, dockPrompt, "dock") then
			return
		end
		local docked = Drives.dockDrive()
		if docked then
			Drives.eject(player)
		elseif Drives.byId[carrying(player) or ""] then
			Drives.dock(player)
		else
			GameState.notify(player, "Bring a hard drive to connect it.", "info")
		end
	end)

	GameState.providers.drives = Drives.snapshot
	GameState.providers.dock = function()
		local d = Drives.dockDrive()
		return if d then d.id else nil
	end

	Players.PlayerRemoving:Connect(function(player)
		Drives.recoverFor(player, player.DisplayName .. " left")
	end)
	Players.PlayerAdded:Connect(function(player)
		player.CharacterRemoving:Connect(function()
			Drives.recoverFor(player, "carrier lost")
		end)
	end)
	for _, player in Players:GetPlayers() do
		player.CharacterRemoving:Connect(function()
			Drives.recoverFor(player, "carrier lost")
		end)
	end
	GameState.RoundReset:Connect(resetRound)

	for _, d in Drives.list do
		refreshVisual(d)
	end
	refreshPrompts()
end

function Drives.start()
	-- watchdog: invalid carriers and drives that left the map
	while true do
		task.wait(Config.DRIVE_WATCHDOG_SECONDS)
		for _, d in Drives.list do
			if d.state == "Carried" then
				local c = d.carrier
				if not c or c.Parent == nil or not Guard.alive(c) or c:GetAttribute("Downed") == true then
					Drives.recover(d, "carrier lost")
				elseif not Layout.inMap(d.part.Position) or d.part.Position.Y < Config.DRIVE_RECOVERY_Y then
					Drives.recover(d, "lost outside")
				end
			end
		end
	end
end

return Drives
