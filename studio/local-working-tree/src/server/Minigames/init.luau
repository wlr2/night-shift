--!strict
-- Common interface for the six SecureErase deletion utilities.
--
-- Every game is pure Luau (no Instances): it builds a randomized state,
-- validates *semantic* actions ("sort file 3 into PURGE", "rotate tile 7"),
-- reports stage clears and produces a client-safe view. The server never
-- accepts a bare "complete" message; completion only happens when the game
-- logic itself reports the final stage cleared.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

export type Result = {
	ok: boolean,
	kind: string, -- "good" | "bad" | "info" | "stageClear" (internal) | "stage" | "complete"
	message: string,
}

export type State = {
	stage: number,
	stages: number,
	mistakes: number, -- in the current stage (drives hints)
	totalMistakes: number,
	rng: Random,
	data: { [string]: any },
}

export type Game = {
	id: string,
	title: string,
	instructions: string,
	newStage: (state: State) -> (), -- (re)build data for state.stage
	act: (state: State, action: string, a: any, b: any) -> Result,
	view: (state: State) -> { [string]: any },
	progress: (state: State) -> number, -- 0..1 within the current stage
	hint: (state: State, level: number) -> (string, any?),
}

export type Job = {
	game: string,
	state: State,
	complete: boolean,
	transitionUntil: number,
	actions: number,
}

local Minigames = {}

local ORDER = { "FileSort", "SectorRepair", "SignalRouting", "Checksum", "MemorySequence", "ProcessCleanup" }
Minigames.ORDER = ORDER

local games: { [string]: Game } = {}
for _, id in ORDER do
	games[id] = (require :: any)(script:WaitForChild(id)) :: Game
end

function Minigames.get(id: string): Game?
	return games[id]
end

-- One distinct game per drive, shuffled per round.
function Minigames.assign(rng: Random): { string }
	local list = table.clone(ORDER)
	for i = #list, 2, -1 do
		local j = rng:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

function Minigames.newJob(gameId: string, solo: boolean, seed: number): Job
	local g = games[gameId]
	assert(g, "unknown minigame " .. gameId)
	local cfg = (Config.MINIGAMES :: any)[gameId]
	local stages = if solo then cfg.stages.solo else cfg.stages.coop
	local state: State = {
		stage = 1,
		stages = stages,
		mistakes = 0,
		totalMistakes = 0,
		rng = Random.new(seed),
		data = {},
	}
	g.newStage(state)
	return { game = gameId, state = state, complete = false, transitionUntil = 0, actions = 0 }
end

function Minigames.hintLevel(state: State): number
	local level = 0
	for i, threshold in Config.HINT_MISTAKES do
		if state.mistakes >= threshold then
			level = i
		end
	end
	return level
end

function Minigames.perform(job: Job, action: string, a: any, b: any): Result
	if job.complete then
		return { ok = false, kind = "info", message = "This drive is already erased." }
	end
	if os.clock() < job.transitionUntil then
		return { ok = false, kind = "info", message = "Erasing sectors... please wait." }
	end
	local g = games[job.game]
	local state = job.state
	job.actions += 1
	local res = g.act(state, action, a, b)
	if res.kind == "bad" then
		state.mistakes += 1
		state.totalMistakes += 1
	elseif res.kind == "stageClear" then
		if state.stage >= state.stages then
			job.complete = true
			return { ok = true, kind = "complete", message = "All stages verified. Drive wiped." }
		end
		state.stage += 1
		state.mistakes = 0
		g.newStage(state)
		job.transitionUntil = os.clock() + Config.STAGE_TRANSITION_SECONDS
		return { ok = true, kind = "stage", message = res.message ~= "" and res.message or "Stage verified." }
	end
	return res
end

-- Forced setback used by events (phantom window misclick, false instruction).
function Minigames.setback(job: Job)
	if job.complete then
		return
	end
	games[job.game].newStage(job.state)
	job.state.mistakes += 1
end

function Minigames.progress(job: Job): number
	if job.complete then
		return 1
	end
	local s = job.state
	local inStage = math.clamp(games[job.game].progress(s), 0, 1)
	return math.clamp(((s.stage - 1) + inStage) / s.stages, 0, 1)
end

function Minigames.view(job: Job): ({ [string]: any }, string?)
	local g = games[job.game]
	local v = g.view(job.state)
	local level = Minigames.hintLevel(job.state)
	local hint: string? = nil
	if level > 0 then
		local text, highlight = g.hint(job.state, level)
		hint = text
		v.highlight = highlight
	end
	v.transitioning = os.clock() < job.transitionUntil
	return v, hint
end

-- Deep copy for checkpoints (Random objects are cloned so replays stay random).
local function deepCopy(v: any): any
	if typeof(v) == "Random" then
		return (v :: Random):Clone()
	elseif type(v) == "table" then
		local out = {}
		for k, x in v do
			out[k] = deepCopy(x)
		end
		return out
	end
	return v
end
Minigames.deepCopy = deepCopy

return Minigames
