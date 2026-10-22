-- Minigame logic specs (pure Luau). Run in Studio Edit mode:
--   load this file into a ModuleScript and call it; it requires the real
--   ServerScriptService.Server.Minigames modules (pure logic, no instances).
-- For every game and many seeds it checks:
--   * a correct solver always finishes every stage (layouts are solvable)
--   * completion is reported exactly once, only after the final stage
--   * random/invalid actions never complete a job and never error
--   * wrong answers increment mistakes (drives the hint system)
return function()
	local Minigames = require(game.ServerScriptService.Server.Minigames)
	local results = {}
	local failures = {}

	local BASE = { I = { 1, 3 }, L = { 1, 2 }, T = { 1, 2, 3 } }
	local function conn(tile, dir)
		for _, b in BASE[tile.kind] do
			if (b - 1 + tile.rot) % 4 + 1 == dir then
				return true
			end
		end
		return false
	end

	-- one correct semantic action for the current state
	local function correctAction(job)
		local d = job.state.data
		local g = job.game
		if g == "FileSort" then
			for _, f in d.files do
				if not f.bin then
					return "sort", f.id, f.target
				end
			end
		elseif g == "SectorRepair" then
			for i, idx in d.current do
				if idx ~= d.target[i] then
					for j, other in d.current do
						if other == d.target[i] then
							return "swap", i, j
						end
					end
				end
			end
		elseif g == "SignalRouting" then
			for i, _ in d.onPath do
				local t, s = d.tiles[i], d.solved[i]
				for dir = 1, 4 do
					if conn(t, dir) ~= conn(s, dir) then
						return "rotate", i, nil
					end
				end
			end
		elseif g == "Checksum" then
			return "match", d.answer, nil
		elseif g == "MemorySequence" then
			return "press", d.seq[d.input + 1], nil
		elseif g == "ProcessCleanup" then
			for gi, grp in d.groups do
				if grp.unlocked and not grp.deleted then
					return "purge", gi, nil
				end
			end
			for _, p in d.procs do
				if p.target and not p.ended then
					return "kill", p.pid, nil
				end
			end
		end
		return nil
	end

	local function wrongAction(job, rng)
		local d = job.state.data
		local g = job.game
		if g == "FileSort" then
			for _, f in d.files do
				if not f.bin then
					return "sort", f.id, if f.target == "purge" then "keep" else "purge"
				end
			end
		elseif g == "Checksum" then
			return "match", (d.answer % #d.records) + 1, nil
		elseif g == "MemorySequence" then
			local exp = d.seq[d.input + 1]
			return "press", (exp % 9) + 1, nil
		elseif g == "ProcessCleanup" then
			for _, p in d.procs do
				if not p.target and not p.ended then
					return "kill", p.pid, nil
				end
			end
		end
		-- garbage input for the rest
		local junk = { "swap", "rotate", "nonsense", "sort" }
		return junk[rng:NextInteger(1, #junk)], rng:NextInteger(-5, 40), "x"
	end

	for _, gameId in Minigames.ORDER do
		local seeds, steps, maxSteps = 0, 0, 0
		for seed = 1, 150 do
			local solo = seed % 2 == 0
			local job = Minigames.newJob(gameId, solo, seed * 7919)
			local rng = Random.new(seed)
			-- 1) junk/wrong actions never complete and never throw
			for _ = 1, 15 do
				local ok, err = pcall(function()
					local a, x, y = wrongAction(job, rng)
					local before = job.state.mistakes
					local res = Minigames.perform(job, a, x, y)
					assert(res.kind ~= "complete", "wrong action completed a job")
					if res.kind == "bad" then
						assert(job.state.mistakes == before + 1, "mistake not counted")
					end
				end)
				if not ok then
					table.insert(failures, gameId .. " seed " .. seed .. ": " .. tostring(err))
					break
				end
				job.transitionUntil = 0
			end
			assert(not job.complete, gameId .. " completed from wrong actions")
			-- 2) solver finishes
			local completions = 0
			local n = 0
			while not job.complete and n < 400 do
				n += 1
				job.transitionUntil = 0
				local a, x, y = correctAction(job)
				if not a then
					table.insert(failures, gameId .. " seed " .. seed .. ": solver found no action at stage " .. job.state.stage)
					break
				end
				local res = Minigames.perform(job, a, x, y)
				if res.kind == "complete" then
					completions += 1
					assert(job.state.stage == job.state.stages, "completed before final stage")
				end
			end
			if not job.complete then
				table.insert(failures, gameId .. " seed " .. seed .. ": not solvable within 400 actions")
			end
			-- 3) no double completion
			job.transitionUntil = 0
			local again = Minigames.perform(job, correctAction(job) or "x", 1, 1)
			assert(again.kind ~= "complete", "double completion")
			if completions ~= 1 then
				table.insert(failures, gameId .. " seed " .. seed .. ": completions=" .. completions)
			end
			seeds += 1
			steps += n
			maxSteps = math.max(maxSteps, n)
		end
		table.insert(results, string.format("%-15s seeds=%d avgSolveActions=%.1f max=%d", gameId, seeds, steps / seeds, maxSteps))
	end
	-- assignment: six distinct games per round
	for s = 1, 50 do
		local order = Minigames.assign(Random.new(s))
		local seen = {}
		for _, g in order do
			assert(not seen[g], "duplicate game in assignment")
			seen[g] = true
		end
		assert(#order == 6, "assignment size")
	end
	table.insert(results, "assignment: 50 rounds, always 6 distinct games")
	table.insert(results, if #failures == 0 then "ALL PASSED" else ("FAILURES (" .. #failures .. "):\n" .. table.concat(failures, "\n", 1, math.min(#failures, 15))))
	return table.concat(results, "\n")
end
