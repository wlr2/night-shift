--!strict
-- 4. CHECKSUM MATCHING: find the record whose symbol checksum matches the
-- target. Decoy records differ by one or two symbols. Symbols are text glyphs
-- with names, never colour alone.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local SYMBOLS = { "#", "@", "%", "&", "+", "=", "*", "?" }
local SURNAMES = { "OSEI", "LIND", "RUIZ", "MERRIN", "HALE", "PARK", "VOSS", "ADEYEMI", "NOVAK", "BRANDT" }
local INITIALS = { "A.", "D.", "J.", "P.", "M.", "K.", "S.", "T." }

local Checksum = {}
Checksum.id = "Checksum"
Checksum.title = "SecureErase :: Checksum Verify"
Checksum.instructions = "Compare the TARGET CHECKSUM with each record. Select the record with the identical symbol pattern."

local function randomPattern(rng: Random, len: number): { string }
	local p = {}
	for i = 1, len do
		p[i] = SYMBOLS[rng:NextInteger(1, #SYMBOLS)]
	end
	return p
end

local function mutate(rng: Random, p: { string }, changes: number): { string }
	local q = table.clone(p)
	local used: { [number]: boolean } = {}
	for _ = 1, changes do
		local i
		repeat
			i = rng:NextInteger(1, #q)
		until not used[i]
		used[i] = true
		local s
		repeat
			s = SYMBOLS[rng:NextInteger(1, #SYMBOLS)]
		until s ~= q[i]
		q[i] = s
	end
	return q
end

local function same(a: { string }, b: { string }): boolean
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

local function newRound(state: any)
	local rng: Random = state.rng
	local d = state.data
	local n = Config.MINIGAMES.Checksum.records[math.min(state.stage, 3)]
	local len = 3 + math.min(state.stage, 3)
	local target = randomPattern(rng, len)
	local records = {}
	local answer = rng:NextInteger(1, n)
	for i = 1, n do
		local pattern
		if i == answer then
			pattern = target
		else
			repeat
				pattern = mutate(rng, target, rng:NextInteger(1, 2))
			until not same(pattern, target)
		end
		records[i] = {
			id = i,
			name = string.format("EMP-%04d %s, %s", rng:NextInteger(100, 9999), SURNAMES[rng:NextInteger(1, #SURNAMES)], INITIALS[rng:NextInteger(1, #INITIALS)]),
			pattern = pattern,
		}
	end
	d.target = target
	d.records = records
	d.answer = answer
end

function Checksum.newStage(state: any)
	state.data = { matched = 0, need = Config.MINIGAMES.Checksum.matchesPerStage }
	newRound(state)
end

function Checksum.act(state: any, action: string, a: any, _b: any)
	local d = state.data
	if action ~= "match" or typeof(a) ~= "number" or a ~= math.floor(a) or a < 1 or a > #d.records then
		return { ok = false, kind = "info", message = "Select a record." }
	end
	if a ~= d.answer then
		d.matched = math.max(0, d.matched - 1)
		newRound(state)
		return { ok = true, kind = "bad", message = "Checksum mismatch. Verification counter -1, new batch loaded." }
	end
	d.matched += 1
	if d.matched >= d.need then
		return { ok = true, kind = "stageClear", message = "Checksums verified." }
	end
	newRound(state)
	return { ok = true, kind = "good", message = string.format("Match %d / %d confirmed.", d.matched, d.need) }
end

function Checksum.view(state: any)
	local d = state.data
	local records = {}
	for _, r in d.records do
		table.insert(records, { id = r.id, name = r.name, pattern = table.concat(r.pattern, " ") })
	end
	return { kind = "Checksum", target = table.concat(d.target, " "), records = records, matched = d.matched, need = d.need }
end

function Checksum.progress(state: any): number
	return state.data.matched / state.data.need
end

function Checksum.hint(state: any, level: number): (string, any?)
	local d = state.data
	if level >= 2 then
		return "Hint: the highlighted record matches.", d.answer
	end
	return "Hint: decoys differ by only one or two symbols. Check every position left to right.", nil
end

return Checksum
