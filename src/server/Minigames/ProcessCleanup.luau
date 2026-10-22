--!strict
-- 6. PROCESS CLEANUP: end the processes the visible rules name. Each correct
-- termination unlocks a file group, which must then be deleted. Ending a
-- protected/innocent process restarts it and re-locks one unlocked group.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local NAMES = { "svchost.exe", "archive_idx.exe", "nightsync.exe", "printspool.exe", "backup_agent.exe", "clockd.exe", "mailq.exe", "lantern_svc.exe", "indexer.exe", "updater.exe" }
local OWNERS = { "SYSTEM", "NIGHTSVC", "ADMIN", "KESSLER" }
local GROUPS = { "payroll_2003\\*", "crew_roster\\*", "incident_logs\\*", "door_access\\*", "timesheets\\*", "mail_archive\\*", "lantern\\*" }

type Proc = { pid: number, name: string, owner: string, cpu: number, protected: boolean, target: boolean, ended: boolean }

local ProcessCleanup = {}
ProcessCleanup.id = "ProcessCleanup"
ProcessCleanup.title = "SecureErase :: Process Cleanup"
ProcessCleanup.instructions = "Select a process and END it if the rules say so. Each correct end unlocks a file group: DELETE the group. Never end a protected process."

local function rulesFor(stage: number, rng: Random)
	local owner = if rng:NextNumber() < 0.5 then "NIGHTSVC" else "KESSLER"
	local cpu = if stage >= 2 then 70 else 101
	local rules = {
		"END processes owned by " .. owner .. ".",
	}
	if cpu <= 100 then
		table.insert(rules, "END any process above " .. cpu .. "% CPU.")
	end
	table.insert(rules, "NEVER end secure_erase.exe or anything owned by SYSTEM.")
	return rules, owner, cpu
end

function ProcessCleanup.newStage(state: any)
	local rng: Random = state.rng
	local s = math.min(state.stage, 3)
	local count = Config.MINIGAMES.ProcessCleanup.processes[s]
	local wantTargets = Config.MINIGAMES.ProcessCleanup.targets[s]
	for _attempt = 1, 60 do
		local rules, owner, cpuLimit = rulesFor(state.stage, rng)
		local procs: { Proc } = {
			{ pid = rng:NextInteger(100, 999), name = "secure_erase.exe", owner = "ADMIN", cpu = rng:NextInteger(20, 95), protected = true, target = false, ended = false },
		}
		local pidBase = rng:NextInteger(1000, 8000)
		for k = 2, count do
			local o = OWNERS[rng:NextInteger(1, #OWNERS)]
			local cpu = rng:NextInteger(1, 99)
			local p: Proc = {
				pid = pidBase + k * 97 + rng:NextInteger(0, 40), -- unique: spacing > jitter
				name = NAMES[rng:NextInteger(1, #NAMES)],
				owner = o,
				cpu = cpu,
				protected = o == "SYSTEM",
				target = false,
				ended = false,
			}
			p.target = not p.protected and (o == owner or cpu > cpuLimit)
			table.insert(procs, p)
		end
		local targets = 0
		for _, p in procs do
			if p.target then
				targets += 1
			end
		end
		if targets == wantTargets then
			-- shuffle display order
			for i = #procs, 2, -1 do
				local j = rng:NextInteger(1, i)
				procs[i], procs[j] = procs[j], procs[i]
			end
			local groups = {}
			for i = 1, targets do
				groups[i] = { name = GROUPS[rng:NextInteger(1, #GROUPS)], unlocked = false, deleted = false }
			end
			state.data = { rules = rules, procs = procs, groups = groups }
			return
		end
	end
	-- deterministic fallback
	local procs: { Proc } = {
		{ pid = 401, name = "secure_erase.exe", owner = "ADMIN", cpu = 40, protected = true, target = false, ended = false },
		{ pid = 1201, name = "nightsync.exe", owner = "NIGHTSVC", cpu = 12, protected = false, target = true, ended = false },
		{ pid = 1202, name = "svchost.exe", owner = "SYSTEM", cpu = 8, protected = true, target = false, ended = false },
		{ pid = 1203, name = "mailq.exe", owner = "NIGHTSVC", cpu = 30, protected = false, target = true, ended = false },
		{ pid = 1204, name = "indexer.exe", owner = "ADMIN", cpu = 5, protected = false, target = false, ended = false },
	}
	state.data = {
		rules = { "END processes owned by NIGHTSVC.", "NEVER end secure_erase.exe or anything owned by SYSTEM." },
		procs = procs,
		groups = { { name = GROUPS[1], unlocked = false, deleted = false }, { name = GROUPS[2], unlocked = false, deleted = false } },
	}
end

function ProcessCleanup.act(state: any, action: string, a: any, _b: any)
	local d = state.data
	if action == "kill" then
		if typeof(a) ~= "number" then
			return { ok = false, kind = "info", message = "Select a process." }
		end
		local proc: Proc? = nil
		for _, p in d.procs do
			if p.pid == a then
				proc = p
			end
		end
		if not proc or proc.ended then
			return { ok = false, kind = "info", message = "That process is not running." }
		end
		if not proc.target then
			-- setback: process restarts and one unlocked group re-locks
			for _, g in d.groups do
				if g.unlocked and not g.deleted then
					g.unlocked = false
					break
				end
			end
			local why = if proc.protected then " is protected" else " is not covered by the rules"
			return { ok = true, kind = "bad", message = proc.name .. why .. ". It restarted and re-locked a group." }
		end
		proc.ended = true
		for _, g in d.groups do
			if not g.unlocked and not g.deleted then
				g.unlocked = true
				return { ok = true, kind = "good", message = proc.name .. " ended. Group " .. g.name .. " unlocked." }
			end
		end
		return { ok = true, kind = "good", message = proc.name .. " ended." }
	elseif action == "purge" then
		if typeof(a) ~= "number" or a ~= math.floor(a) or a < 1 or a > #d.groups then
			return { ok = false, kind = "info", message = "Select a file group." }
		end
		local g = d.groups[a]
		if g.deleted then
			return { ok = false, kind = "info", message = "Already deleted." }
		end
		if not g.unlocked then
			return { ok = false, kind = "info", message = "Locked: a process is still holding these files." }
		end
		g.deleted = true
		for _, other in d.groups do
			if not other.deleted then
				return { ok = true, kind = "good", message = g.name .. " deleted." }
			end
		end
		return { ok = true, kind = "stageClear", message = "All file groups deleted." }
	end
	return { ok = false, kind = "info", message = "Unknown command." }
end

function ProcessCleanup.view(state: any)
	local d = state.data
	local procs = {}
	for _, p in d.procs do
		table.insert(procs, { pid = p.pid, name = p.name, owner = p.owner, cpu = p.cpu, ended = p.ended })
	end
	local groups = {}
	for i, g in d.groups do
		groups[i] = { name = g.name, unlocked = g.unlocked, deleted = g.deleted }
	end
	return { kind = "ProcessCleanup", rules = d.rules, procs = procs, groups = groups }
end

function ProcessCleanup.progress(state: any): number
	local d = state.data
	local score, total = 0, #d.groups * 2
	for _, g in d.groups do
		if g.deleted then
			score += 2
		elseif g.unlocked then
			score += 1
		end
	end
	return score / total
end

function ProcessCleanup.hint(state: any, level: number): (string, any?)
	local d = state.data
	if level >= 2 then
		for _, p in d.procs do
			if p.target and not p.ended then
				return "Hint: " .. p.name .. " (PID " .. p.pid .. ") matches a rule.", p.pid
			end
		end
	end
	return "Hint: compare OWNER and CPU with each rule. SYSTEM processes are protected.", nil
end

return ProcessCleanup
