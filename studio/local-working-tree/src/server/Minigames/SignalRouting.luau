--!strict
-- 3. SIGNAL ROUTING: rotate tiles to carry the purge signal from IN (left
-- edge) to OUT (right edge). Puzzles are generated from a known solvable path
-- and then scrambled, so every layout is solvable by construction.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

-- directions: 1 = N, 2 = E, 3 = S, 4 = W
local DX = { 0, 1, 0, -1 }
local DY = { -1, 0, 1, 0 }
local BASE: { [string]: { number } } = {
	I = { 1, 3 },
	L = { 1, 2 },
	T = { 1, 2, 3 },
}

local function opposite(d: number): number
	return (d + 1) % 4 + 1
end

local function rotateDir(d: number, r: number): number
	return (d - 1 + r) % 4 + 1
end

local function connects(tile: any, dir: number): boolean
	for _, d in BASE[tile.kind] do
		if rotateDir(d, tile.rot) == dir then
			return true
		end
	end
	return false
end

local function idx(w: number, x: number, y: number): number
	return (y - 1) * w + x
end

local function powered(d: any): ({ [number]: boolean }, boolean)
	local w, h = d.w, d.h
	local lit: { [number]: boolean } = {}
	local start = idx(w, 1, d.inRow)
	if not connects(d.tiles[start], 4) then
		return lit, false
	end
	local queue = { { 1, d.inRow } }
	lit[start] = true
	local reached = false
	while #queue > 0 do
		local cur = table.remove(queue, 1) :: { number }
		local x, y = cur[1], cur[2]
		local t = d.tiles[idx(w, x, y)]
		if x == w and y == d.outRow and connects(t, 2) then
			reached = true
		end
		for dir = 1, 4 do
			if connects(t, dir) then
				local nx, ny = x + DX[dir], y + DY[dir]
				if nx >= 1 and nx <= w and ny >= 1 and ny <= h then
					local ni = idx(w, nx, ny)
					if not lit[ni] and connects(d.tiles[ni], opposite(dir)) then
						lit[ni] = true
						table.insert(queue, { nx, ny })
					end
				end
			end
		end
	end
	return lit, reached
end

local SignalRouting = {}
SignalRouting.id = "SignalRouting"
SignalRouting.title = "SecureErase :: Signal Router"
SignalRouting.instructions = "Click a tile to rotate it. Connect the purge signal from IN on the left to OUT on the right. Lit tiles carry the signal."

-- random self-avoiding walk from the left edge to the right edge
local function makePath(rng: Random, w: number, h: number, inRow: number): { { number } }?
	local path = { { 1, inRow } }
	local seen: { [number]: boolean } = { [idx(w, 1, inRow)] = true }
	local guard = 0
	while guard < 400 do
		guard += 1
		local cur = path[#path]
		if cur[1] == w then
			return path
		end
		local options = {}
		for dir = 1, 3 do -- N, E, S (never west keeps paths short and readable)
			local nx, ny = cur[1] + DX[dir], cur[2] + DY[dir]
			if nx >= 1 and nx <= w and ny >= 1 and ny <= h and not seen[idx(w, nx, ny)] then
				local weight = if dir == 2 then 2 else 1
				for _ = 1, weight do
					table.insert(options, { nx, ny })
				end
			end
		end
		if #options == 0 then
			return nil
		end
		local nxt = options[rng:NextInteger(1, #options)]
		seen[idx(w, nxt[1], nxt[2])] = true
		table.insert(path, nxt)
	end
	return nil
end

local function tileFor(need: { number }): (string, number)
	local a, b = need[1], need[2]
	if opposite(a) == b then
		return "I", if a == 1 or a == 3 then 0 else 1
	end
	-- corner: find rotation r such that {N,E} rotated = {a,b}
	for r = 0, 3 do
		local c1, c2 = rotateDir(1, r), rotateDir(2, r)
		if (c1 == a and c2 == b) or (c1 == b and c2 == a) then
			return "L", r
		end
	end
	return "I", 0
end

function SignalRouting.newStage(state: any)
	local rng: Random = state.rng
	local size = Config.MINIGAMES.SignalRouting.grid[math.min(state.stage, 3)]
	local w, h = size[1], size[2]
	local inRow = rng:NextInteger(1, h)
	local found: { { number } }? = nil
	while not found do
		found = makePath(rng, w, h, inRow)
	end
	local path = found :: { { number } }
	local outRow = path[#path][2]
	local tiles = {}
	local onPath: { [number]: boolean } = {}
	for i, cell in path do
		local x, y = cell[1], cell[2]
		local need = {}
		if i == 1 then
			table.insert(need, 4)
		else
			local p = path[i - 1]
			for dir = 1, 4 do
				if x + DX[dir] == p[1] and y + DY[dir] == p[2] then
					table.insert(need, dir)
				end
			end
		end
		if i == #path then
			table.insert(need, 2)
		else
			local n = path[i + 1]
			for dir = 1, 4 do
				if x + DX[dir] == n[1] and y + DY[dir] == n[2] then
					table.insert(need, dir)
				end
			end
		end
		local kind, rot = tileFor(need)
		tiles[idx(w, x, y)] = { kind = kind, rot = rot }
		onPath[idx(w, x, y)] = true
	end
	local kinds = { "I", "L", "T", "L" }
	for y = 1, h do
		for x = 1, w do
			local i = idx(w, x, y)
			if not tiles[i] then
				tiles[i] = { kind = kinds[rng:NextInteger(1, #kinds)], rot = rng:NextInteger(0, 3) }
			end
		end
	end
	-- remember solved orientation masks, then scramble until unsolved
	local solved = {}
	for i, t in tiles do
		solved[i] = { kind = t.kind, rot = t.rot }
	end
	state.data = { w = w, h = h, inRow = inRow, outRow = outRow, tiles = tiles, solved = solved, onPath = onPath, rotations = 0 }
	repeat
		for _, t in tiles do
			t.rot = (t.rot + rng:NextInteger(0, 3)) % 4
		end
		local _, done = powered(state.data)
	until not done
end

local function tileCorrect(d: any, i: number): boolean
	local t, s = d.tiles[i], d.solved[i]
	for dir = 1, 4 do
		if connects(t, dir) ~= connects(s, dir) then
			return false
		end
	end
	return true
end

function SignalRouting.act(state: any, action: string, a: any, _b: any)
	local d = state.data
	if action ~= "rotate" or typeof(a) ~= "number" or a ~= math.floor(a) or a < 1 or a > d.w * d.h then
		return { ok = false, kind = "info", message = "Click a tile to rotate it." }
	end
	local wasCorrect = d.onPath[a] and tileCorrect(d, a)
	d.tiles[a].rot = (d.tiles[a].rot + 1) % 4
	d.rotations += 1
	local _, done = powered(d)
	if done then
		return { ok = true, kind = "stageClear", message = "Purge signal routed." }
	end
	if wasCorrect and not tileCorrect(d, a) and d.rotations > d.w * d.h then
		return { ok = true, kind = "bad", message = "Signal path broken. Follow the lit tiles." }
	end
	return { ok = true, kind = "info", message = "" }
end

function SignalRouting.view(state: any)
	local d = state.data
	local lit = powered(d)
	local tiles = {}
	for i, t in d.tiles do
		tiles[i] = { kind = t.kind, rot = t.rot, lit = lit[i] == true }
	end
	return { kind = "SignalRouting", w = d.w, h = d.h, inRow = d.inRow, outRow = d.outRow, tiles = tiles }
end

function SignalRouting.progress(state: any): number
	local d = state.data
	local total, good = 0, 0
	for i in d.onPath do
		total += 1
		if tileCorrect(d, i) then
			good += 1
		end
	end
	return if total > 0 then good / total * 0.95 else 0
end

function SignalRouting.hint(state: any, level: number): (string, any?)
	local d = state.data
	if level >= 2 then
		local first: number? = nil
		for y = 1, d.h do
			for x = 1, d.w do
				local i = idx(d.w, x, y)
				if d.onPath[i] and not tileCorrect(d, i) and (first == nil or x < ((first - 1) % d.w) + 1) then
					first = i
				end
			end
		end
		if first then
			return "Hint: the highlighted tile is on the route but turned the wrong way.", first
		end
	end
	return string.format("Hint: the signal enters on row %d and must leave on row %d.", d.inRow, d.outRow), nil
end

return SignalRouting
