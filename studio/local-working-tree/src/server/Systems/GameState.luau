--!strict
-- Authoritative team/round state and its replication. Other systems mutate
-- their own state, then call GameState.markDirty(); a throttled loop sends a
-- full snapshot (cheap: the game state is small) so late joiners and every
-- client always render the same truth.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Types = require(ReplicatedStorage.Shared.Types)

type Phase = Types.Phase

local GameState = {}

GameState.phase = "Briefing" :: Phase
GameState.data = {
	erased = 0,
	fragments = {} :: { number },
	boss = {} :: { Types.BossMessage },
	purge = nil :: { { name: string, cancelled: boolean, locked: boolean, userId: number? } }?,
	purgeDeadline = nil :: number?,
	signOff = nil :: { progress: number, awaiting: boolean, paused: boolean }?,
	clockedOut = {} :: { string },
	frontDoorOpen = false,
	checkpoints = 0,
	threats = {} :: { Types.ThreatInfo },
	roundStart = os.clock(),
	round = 1,
	serverClockOffset = 0,
}

GameState.PhaseChanged = Signal.new() :: Signal.Signal<Phase, Phase>
GameState.RoundReset = Signal.new() :: Signal.Signal<>
GameState.PlayerCountChanged = Signal.new() :: Signal.Signal<number>
GameState.BossAnswered = Signal.new() :: Signal.Signal<number, string, Player>

-- providers: other systems plug their slice of the snapshot in
type Providers = {
	drives: (() -> { Types.DriveSnapshot })?,
	power: (() -> { main: boolean, lights: boolean, workstation: boolean, warning: boolean })?,
	door: (() -> Types.DoorState)?,
	dock: (() -> string?)?,
	operator: (() -> string?)?,
	objective: (() -> string)?,
}
GameState.providers = {} :: Providers

local dirty = true
local nextBossId = 1

function GameState.markDirty()
	dirty = true
end

function GameState.setPhase(p: Phase)
	local old: Phase = GameState.phase :: Phase
	if old == p then
		return
	end
	GameState.phase = p
	dirty = true
	GameState.PhaseChanged:Fire(p, old)
end

function GameState.nightMinutes(): number
	local elapsed = os.clock() - GameState.data.roundStart
	return (Config.NIGHT_START_MINUTES + elapsed * Config.GAME_MINUTES_PER_SECOND) % (24 * 60)
end

-- Players who count for difficulty and team wipes: connected, spawned, still inside.
function GameState.activePlayers(): { Player }
	local list = {}
	for _, p in Players:GetPlayers() do
		if p.Character and p:GetAttribute("Escaped") ~= true then
			table.insert(list, p)
		end
	end
	return list
end

function GameState.playerCount(): number
	return math.max(1, #Players:GetPlayers())
end

function GameState.isSolo(): boolean
	return #Players:GetPlayers() <= 1
end

function GameState.notify(target: Player?, text: string, kind: string?)
	local r = Net.remote("Notify")
	if target then
		r:FireClient(target, text, kind or "info")
	else
		r:FireAllClients(text, kind or "info")
	end
end

function GameState.fx(name: string, data: any?, target: Player?)
	local r = Net.remote("Fx")
	if target then
		r:FireClient(target, name, data)
	else
		r:FireAllClients(name, data)
	end
end

-- Boss/system messages shown in the desktop messenger and as HUD pager toasts.
function GameState.bossMessage(text: string, kind: string?, choices: { string }?, from: string?): number
	local id = nextBossId
	nextBossId += 1
	local msg: Types.BossMessage = {
		id = id,
		from = from or "R. Kessler",
		text = text,
		kind = kind or "info",
		choices = choices,
		answered = nil,
		t = GameState.nightMinutes(),
	}
	table.insert(GameState.data.boss, msg)
	while #GameState.data.boss > 14 do
		table.remove(GameState.data.boss, 1)
	end
	dirty = true
	GameState.fx("BossMessage", { id = id, from = msg.from, text = text, kind = msg.kind })
	return id
end

function GameState.findBoss(id: number): Types.BossMessage?
	for _, m in GameState.data.boss do
		if m.id == id then
			return m
		end
	end
	return nil
end

function GameState.answerBoss(id: number, choice: string, by: Player): boolean
	local m = GameState.findBoss(id)
	if not m or m.answered or not m.choices or not table.find(m.choices, choice) then
		return false
	end
	m.answered = choice
	dirty = true
	GameState.BossAnswered:Fire(id, choice, by)
	return true
end

function GameState.setThreat(id: string, label: string?, urgent: boolean?, where: string?)
	local threats = GameState.data.threats
	for i, t in threats do
		if t.id == id then
			if label then
				t.label = label
				t.urgent = urgent == true
				t.where = where
			else
				table.remove(threats, i)
			end
			dirty = true
			return
		end
	end
	if label then
		table.insert(threats, { id = id, label = label, urgent = urgent == true, where = where })
		dirty = true
	end
end

function GameState.clearThreats()
	table.clear(GameState.data.threats)
	dirty = true
end

function GameState.snapshot(): Types.Snapshot
	local d = GameState.data
	local P = GameState.providers
	local power = if P.power then P.power() else { main = true, lights = true, workstation = true, warning = false }
	return {
		phase = GameState.phase :: Phase,
		erased = d.erased,
		total = Config.DRIVE_COUNT,
		nightMinutes = GameState.nightMinutes(),
		power = power,
		door = if P.door then P.door() else "Latched",
		threats = d.threats,
		drives = if P.drives then P.drives() else {},
		dock = if P.dock then P.dock() else nil,
		operator = if P.operator then P.operator() else nil,
		boss = d.boss,
		fragments = d.fragments,
		purge = d.purge,
		-- sent as seconds remaining (server clocks are not comparable on clients)
		purgeDeadline = if d.purgeDeadline then math.max(0, d.purgeDeadline - os.clock()) else nil,
		signOff = d.signOff,
		clockedOut = d.clockedOut,
		frontDoorOpen = d.frontDoorOpen,
		objective = if P.objective then P.objective() else "",
		checkpoints = d.checkpoints,
		serverTime = workspace:GetServerTimeNow(),
		soloMode = GameState.isSolo(),
	}
end

function GameState.init()
	Players.PlayerAdded:Connect(function(player)
		dirty = true
		GameState.PlayerCountChanged:Fire(#Players:GetPlayers())
		task.defer(function()
			Net.remote("State"):FireClient(player, GameState.snapshot())
		end)
	end)
	Players.PlayerRemoving:Connect(function()
		dirty = true
		task.defer(function()
			GameState.PlayerCountChanged:Fire(#Players:GetPlayers())
		end)
	end)
end

function GameState.start()
	local stateRemote = Net.remote("State")
	local lastSent = 0
	while true do
		task.wait(0.2)
		local now = os.clock()
		if dirty or now - lastSent > 2 then
			dirty = false
			lastSent = now
			stateRemote:FireAllClients(GameState.snapshot())
		end
	end
end

return GameState
