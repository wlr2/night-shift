--!strict
-- Difficulty director. No timetable: every roll picks among ELIGIBLE events
-- with weighted randomness, using erased-drive progress, puzzle progress,
-- active player count, unresolved threats, cooldowns, recent history,
-- learned mechanics and recovery windows. Urgent threats are capped (solo: one
-- at a time) and the finale has a hard cap so sign-off always completes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Server = script.Parent.Parent
local Minigames = require(Server.Minigames)
local GameState = require(script.Parent.GameState)
local Drives = require(script.Parent.Drives)
local Doors = require(script.Parent.Doors)
local Power = require(script.Parent.Power)
local Workstation = require(script.Parent.Workstation)
local Threat = require(script.Parent.Threat)
local PlayerStatus = require(script.Parent.PlayerStatus)
local Checkpoints = require(script.Parent.Checkpoints)

export type Ctx = {
	now: number,
	tier: string,
	phase: string,
	erased: number,
	players: number,
	solo: boolean,
	urgentActive: number,
	urgentCap: number,
	learned: { [string]: boolean },
	operator: Player?,
	processing: boolean,
	puzzleProgress: number?,
	stageProgress: number?,
	threatBusy: boolean,
	powerOk: boolean,
	doorLatched: boolean,
	anyDowned: boolean,
	active: { [string]: boolean },
	opts: { [string]: any },
}

export type Handle = {
	urgentNow: (() -> boolean)?,
	cleanup: () -> (),
}

export type EventDef = {
	id: string,
	urgent: boolean,
	mechanic: string?,
	cooldown: number,
	conflicts: { string },
	eligible: (ctx: Ctx) -> boolean,
	weight: (ctx: Ctx) -> number,
	start: (ctx: Ctx, finish: (outcome: string) -> ()) -> Handle,
	setup: (() -> ())?,
}

type Active = { def: EventDef, handle: Handle?, started: number, urgent: boolean }

local EventDirector = {}

local defs: { EventDef } = {}
local byId: { [string]: EventDef } = {}
local active: { [string]: Active } = {}
local lastRun: { [string]: number } = {}
local history: { string } = {}
local learned: { [string]: boolean } = {}
local nextRollAt = 0
local recoveryUntil = 0
local lastUrgentEnded = -math.huge
local finaleUrgentUsed = 0
local purgeUrgentUsed = 0
local shiftStart = os.clock()
local log: { string } = {}

local function record(text: string)
	table.insert(log, string.format("[%5.1f] %s", os.clock() - shiftStart, text))
	while #log > 40 do
		table.remove(log, 1)
	end
end

local function urgentCount(): number
	local n = 0
	for _, a in active do
		local h = a.handle
		if a.urgent or (h and h.urgentNow and h.urgentNow()) then
			n += 1
		end
	end
	return n
end

local function buildCtx(opts: { [string]: any }?): Ctx
	local players = #GameState.activePlayers()
	local d = Drives.dockDrive()
	local processing = d ~= nil and d.state == "Processing" and d.job ~= nil
	local progress: number? = nil
	local stageProgress: number? = nil
	if processing and d and d.job then
		progress = Minigames.progress(d.job)
		local g = Minigames.get(d.game)
		if g then
			stageProgress = g.progress(d.job.state)
		end
	end
	local anyDowned = false
	for _, p in GameState.activePlayers() do
		if PlayerStatus.isDowned(p) then
			anyDowned = true
		end
	end
	local activeSet = {}
	for id in active do
		activeSet[id] = true
	end
	return {
		now = os.clock(),
		tier = Config.tierFor(GameState.data.erased, GameState.phase),
		phase = GameState.phase,
		erased = GameState.data.erased,
		players = math.max(1, players),
		solo = GameState.isSolo(),
		urgentActive = urgentCount(),
		urgentCap = Config.urgentCap(math.max(1, players)),
		learned = learned,
		operator = Workstation.operator(),
		processing = processing,
		puzzleProgress = progress,
		stageProgress = stageProgress,
		threatBusy = Threat.busy(),
		powerOk = not Power.anyTripped(),
		doorLatched = Doors.state() == "Latched",
		anyDowned = anyDowned,
		active = activeSet,
		opts = opts or {},
	}
end

local function finishFor(id: string, entry: Active): (outcome: string) -> ()
	local done = false
	return function(outcome: string)
		if done then
			return
		end
		done = true
		local a = active[id]
		if not a or a ~= entry then -- a late callback from an older run
			return
		end
		active[id] = nil
		local def = a.def
		if def.mechanic then
			learned[def.mechanic] = true
		end
		lastRun[id] = os.clock()
		if a.urgent then
			local tier = Config.tierFor(GameState.data.erased, GameState.phase)
			lastUrgentEnded = os.clock()
			recoveryUntil = math.max(recoveryUntil, os.clock() + (Config.DIRECTOR.recoveryAfterUrgent :: any)[tier])
		end
		record(id .. " ended: " .. outcome)
		GameState.markDirty()
	end
end

local function startEvent(def: EventDef, opts: { [string]: any }?)
	if active[def.id] then
		return
	end
	local ctx = buildCtx(opts)
	local entry: Active = { def = def, handle = nil, started = os.clock(), urgent = def.urgent }
	active[def.id] = entry
	lastRun[def.id] = os.clock()
	table.insert(history, def.id)
	while #history > Config.DIRECTOR.historySize do
		table.remove(history, 1)
	end
	if def.urgent then
		if GameState.phase == "SignOff" then
			finaleUrgentUsed += 1
		elseif GameState.phase == "FinalPurge" then
			purgeUrgentUsed += 1
		end
	end
	record("start " .. def.id .. " (tier " .. ctx.tier .. ", players " .. ctx.players .. ")")
	local ok, handle = pcall(def.start, ctx, finishFor(def.id, entry))
	if ok then
		entry.handle = handle
	else
		warn("[Director] event failed to start", def.id, handle)
		active[def.id] = nil
	end
end

local function conflicts(def: EventDef): boolean
	for _, other in def.conflicts do
		if active[other] then
			return true
		end
	end
	for id, a in active do
		if table.find(a.def.conflicts, def.id) then
			return true
		end
		local _ = id
	end
	return false
end

local function phaseAllowsEvents(): boolean
	local p = GameState.phase
	return p == "Work" or p == "FinalPurge" or p == "SignOff" or p == "ClockOut"
end

local function urgentAllowedNow(ctx: Ctx): boolean
	if ctx.anyDowned or ctx.now < recoveryUntil then
		return false
	end
	if ctx.urgentActive >= ctx.urgentCap then
		return false
	end
	local solo = ctx.solo
	if ctx.phase == "SignOff" then
		return finaleUrgentUsed < (if solo then Config.DIRECTOR.signOffMaxUrgent.solo else Config.DIRECTOR.signOffMaxUrgent.coop)
	elseif ctx.phase == "FinalPurge" then
		return purgeUrgentUsed < Config.DIRECTOR.finalPurgeMaxUrgent
	elseif ctx.phase == "ClockOut" then
		return false -- the finale pursuit is the only threat while clocking out
	end
	return true
end

local function roll()
	local ctx = buildCtx()
	local candidates: { { def: EventDef, w: number } } = {}
	local total = 0
	local relief = os.clock() - lastUrgentEnded < 60
	for _, def in defs do
		local cd = lastRun[def.id]
		local ready = cd == nil or ctx.now - cd >= def.cooldown
		if ready and not active[def.id] and not conflicts(def) and (not def.urgent or urgentAllowedNow(ctx)) and def.eligible(ctx) then
			local w = def.weight(ctx)
			-- repeat penalty
			if history[#history] == def.id then
				w *= Config.DIRECTOR.repeatPenaltyLast
			elseif table.find(history, def.id) then
				w *= Config.DIRECTOR.repeatPenaltyRecent
			end
			-- alternate tension and relief
			if relief and not def.urgent then
				w *= Config.DIRECTOR.reliefBoostAfterUrgent
			end
			-- let an almost-finished stage finish
			if def.urgent and (ctx.stageProgress or 0) > 0.7 then
				w *= Config.DIRECTOR.nearCompleteUrgentScale
			end
			if w > 0 then
				table.insert(candidates, { def = def, w = w })
				total += w
			end
		end
	end
	if total <= 0 then
		return
	end
	local pick = math.random() * total
	for _, c in candidates do
		pick -= c.w
		if pick <= 0 then
			startEvent(c.def)
			return
		end
	end
	startEvent(candidates[#candidates].def)
end

local function scheduleNext()
	local tier = Config.tierFor(GameState.data.erased, GameState.phase)
	local gap = (Config.DIRECTOR.gaps :: any)[tier]
	nextRollAt = os.clock() + gap[1] + math.random() * (gap[2] - gap[1])
end

function EventDirector.cleanupAll(reason: string)
	for id, a in active do
		if a.handle then
			pcall(a.handle.cleanup)
		end
		active[id] = nil
	end
	GameState.clearThreats()
	record("cleanup all: " .. reason)
end

function EventDirector.grantRecovery(seconds: number)
	recoveryUntil = math.max(recoveryUntil, os.clock() + seconds)
end

function EventDirector.trigger(id: string, opts: { [string]: any }?): boolean
	local def = byId[id]
	if not def or active[id] then
		return false
	end
	startEvent(def, opts)
	return true
end

function EventDirector.debugState(): { [string]: any }
	local act = {}
	for id in active do
		table.insert(act, id)
	end
	return {
		active = act,
		history = history,
		learned = learned,
		nextRollIn = nextRollAt - os.clock(),
		recoveryFor = recoveryUntil - os.clock(),
		log = log,
	}
end

function EventDirector.init()
	local folder = Server:WaitForChild("Events")
	for _, m in folder:GetChildren() do
		if m:IsA("ModuleScript") then
			local def = (require :: any)(m) :: EventDef
			table.insert(defs, def)
			byId[def.id] = def
			if def.setup then
				def.setup()
			end
		end
	end
	table.sort(defs, function(a, b)
		return a.id < b.id
	end)
	Checkpoints.Restoring:Connect(function()
		EventDirector.cleanupAll("checkpoint restore")
	end)
	Checkpoints.Restored:Connect(function()
		recoveryUntil = os.clock() + Config.DOWNED.restoreRecoverySeconds
		scheduleNext()
	end)
	GameState.RoundReset:Connect(function()
		EventDirector.cleanupAll("round reset")
		table.clear(learned)
		table.clear(lastRun)
		table.clear(history)
		finaleUrgentUsed = 0
		purgeUrgentUsed = 0
		shiftStart = os.clock()
		nextRollAt = os.clock() + Config.PHASE.directorGraceSeconds
	end)
	GameState.PhaseChanged:Connect(function(new)
		if new == "SignOff" then
			finaleUrgentUsed = 0
			scheduleNext()
		elseif new == "FinalPurge" then
			purgeUrgentUsed = 0
			nextRollAt = os.clock() + 20
		elseif new == "ClockOut" or new == "Ending" then
			for id, a in active do
				if a.def.urgent and a.handle then
					pcall(a.handle.cleanup)
					active[id] = nil
				end
			end
		end
	end)
	nextRollAt = os.clock() + Config.PHASE.directorGraceSeconds
end

function EventDirector.start()
	while true do
		task.wait(Config.DIRECTOR.tickSeconds)
		if phaseAllowsEvents() and not Checkpoints.isRestoring() then
			-- unsecured door left by players: same counterplay as an unlatch event
			if Doors.state() ~= "Latched" and not active.DoorUnlatch and not Threat.busy() then
				local tier = Config.tierFor(GameState.data.erased, GameState.phase)
				local grace = (Config.EVENTS.DoorUnlatch.grace :: any)[tier]
				if Doors.unsecuredFor() > grace and urgentCount() < Config.urgentCap(#GameState.activePlayers()) and GameState.phase ~= "ClockOut" then
					startEvent(byId.DoorUnlatch, { watch = true })
				end
			end
			if os.clock() >= nextRollAt then
				roll()
				scheduleNext()
			end
		end
	end
end

return EventDirector
