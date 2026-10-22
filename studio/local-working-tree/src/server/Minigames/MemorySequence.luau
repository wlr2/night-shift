--!strict
-- 5. MEMORY SEQUENCE: watch blocks light up, then repeat the order.
-- REPLAY shows it again at a small cost (input restarts and the replay
-- counter shortens the next playback window). A wrong press restarts input
-- and replays automatically; it never erases earlier stages.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local MemorySequence = {}
MemorySequence.id = "MemorySequence"
MemorySequence.title = "SecureErase :: Sector Memory Map"
MemorySequence.instructions = "Watch the blocks light up, then click them in the same order. REPLAY shows the sequence again but restarts your input."

function MemorySequence.newStage(state: any)
	local rng: Random = state.rng
	local len = Config.MINIGAMES.MemorySequence.length[math.min(state.stage, 3)]
	local seq = {}
	local last = 0
	for i = 1, len do
		local c
		repeat
			c = rng:NextInteger(1, 9)
		until c ~= last
		seq[i] = c
		last = c
	end
	state.data = { seq = seq, input = 0, playId = 1, replays = 0 }
end

function MemorySequence.act(state: any, action: string, a: any, _b: any)
	local d = state.data
	if action == "replay" then
		d.input = 0
		d.playId += 1
		d.replays += 1
		return { ok = true, kind = "info", message = "Replaying sequence. Input restarted." }
	end
	if action ~= "press" or typeof(a) ~= "number" or a ~= math.floor(a) or a < 1 or a > 9 then
		return { ok = false, kind = "info", message = "Click a block." }
	end
	local expected = d.seq[d.input + 1]
	if a ~= expected then
		d.input = 0
		d.playId += 1
		return { ok = true, kind = "bad", message = "Wrong block. Watch again." }
	end
	d.input += 1
	if d.input >= #d.seq then
		return { ok = true, kind = "stageClear", message = "Memory map confirmed." }
	end
	return { ok = true, kind = "good", message = string.format("%d / %d", d.input, #d.seq) }
end

function MemorySequence.view(state: any)
	local d = state.data
	return {
		kind = "MemorySequence",
		seq = d.seq, -- the client must show the sequence to play it back
		input = d.input,
		length = #d.seq,
		playId = d.playId,
		replays = d.replays,
	}
end

function MemorySequence.progress(state: any): number
	return state.data.input / #state.data.seq
end

function MemorySequence.hint(state: any, level: number): (string, any?)
	local d = state.data
	if level >= 3 then
		return "Hint: the next block is highlighted.", d.seq[d.input + 1]
	elseif level >= 2 then
		return "Hint: playback is slowed down. The first block is highlighted.", d.seq[1]
	end
	return "Hint: say the block positions to yourself as they flash (top-left, middle...).", nil
end

return MemorySequence
