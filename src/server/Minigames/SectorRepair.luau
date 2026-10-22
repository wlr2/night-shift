--!strict
-- 2. SECTOR REPAIR: swap sectors until the row matches the displayed sequence.
-- Each sector has a number, a letter and a colour (colour is never the only cue).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local LETTERS = { "A", "B", "C", "D", "E", "F", "G", "H" }
local COLORS = { "amber", "teal", "rose", "lime", "violet", "sky", "sand", "slate" }

local SectorRepair = {}
SectorRepair.id = "SectorRepair"
SectorRepair.title = "SecureErase :: Sector Repair"
SectorRepair.instructions = "Damaged sectors are out of order. Select two slots to swap them until the row matches TARGET ORDER."

local function correctCount(d: any): number
	local n = 0
	for i, s in d.current do
		if s == d.target[i] then
			n += 1
		end
	end
	return n
end

function SectorRepair.newStage(state: any)
	local rng: Random = state.rng
	local n = Config.MINIGAMES.SectorRepair.sectors[math.min(state.stage, 3)]
	local pool = {}
	for i = 1, #LETTERS do
		table.insert(pool, { label = string.format("%02d%s", rng:NextInteger(10, 99), LETTERS[i]), color = COLORS[i] })
	end
	-- random target order of n distinct sectors
	for i = #pool, 2, -1 do
		local j = rng:NextInteger(1, i)
		pool[i], pool[j] = pool[j], pool[i]
	end
	local sectors = {}
	local target = {}
	for i = 1, n do
		sectors[i] = pool[i]
		target[i] = i
	end
	local current = table.clone(target)
	repeat
		for i = n, 2, -1 do
			local j = rng:NextInteger(1, i)
			current[i], current[j] = current[j], current[i]
		end
	until correctCount({ current = current, target = target }) <= math.max(1, n // 3)
	state.data.sectors = sectors
	state.data.target = target
	state.data.current = current
	state.data.swaps = 0
end

function SectorRepair.act(state: any, action: string, a: any, b: any)
	local d = state.data
	local n = #d.current
	if action ~= "swap" or typeof(a) ~= "number" or typeof(b) ~= "number" then
		return { ok = false, kind = "info", message = "Select two slots." }
	end
	if a ~= math.floor(a) or b ~= math.floor(b) or a < 1 or b < 1 or a > n or b > n or a == b then
		return { ok = false, kind = "info", message = "Select two different slots." }
	end
	local before = correctCount(d)
	d.current[a], d.current[b] = d.current[b], d.current[a]
	d.swaps += 1
	local after = correctCount(d)
	if after == n then
		return { ok = true, kind = "stageClear", message = "Sector chain rebuilt." }
	end
	if after < before then
		return { ok = true, kind = "bad", message = "That swap broke a sector that was already in place." }
	end
	if after > before then
		return { ok = true, kind = "good", message = string.format("%d / %d sectors aligned.", after, n) }
	end
	return { ok = true, kind = "info", message = "Swapped. No sector aligned yet." }
end

function SectorRepair.view(state: any)
	local d = state.data
	local target = {}
	local current = {}
	for i, idx in d.target do
		target[i] = { label = d.sectors[idx].label, color = d.sectors[idx].color }
	end
	for i, idx in d.current do
		current[i] = { label = d.sectors[idx].label, color = d.sectors[idx].color, ok = idx == d.target[i] }
	end
	return { kind = "SectorRepair", target = target, current = current }
end

function SectorRepair.progress(state: any): number
	return correctCount(state.data) / #state.data.current
end

function SectorRepair.hint(state: any, level: number): (string, any?)
	local d = state.data
	for i, idx in d.current do
		if idx ~= d.target[i] then
			if level >= 2 then
				for j, other in d.current do
					if other == d.target[i] then
						return string.format("Hint: swap slot %d with slot %d.", i, j), { i, j }
					end
				end
			end
			return string.format("Hint: slot %d should hold sector %s.", i, d.sectors[d.target[i]].label), nil
		end
	end
	return "Hint: match each slot to the TARGET ORDER above it.", nil
end

return SectorRepair
