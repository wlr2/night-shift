--!strict
-- 1. FILE SORTING: select a file, then PURGE or KEEP, following visible rules.
-- Rules are evaluated top-down; EXCEPTION lines override the rule above.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

type File = { id: number, name: string, ext: string, year: number, dept: string, tag: string, target: string, bin: string? }
type Rule = { text: string, test: (File) -> string? }

local DEPTS = { "ACCOUNTS", "PERSONNEL", "NIGHT CREW", "FACILITIES" }
local EXTS = { "doc", "xls", "bak", "tmp", "log", "txt" }
local TAGS = { "", "", "", "LEGAL HOLD", "CONFIDENTIAL" }
local NAMES = { "timesheet", "roster", "invoice", "memo", "shiftlog", "report", "payroll", "incident", "notes", "audit" }

local function ruleSet(stage: number, rng: Random): { Rule }
	local year = rng:NextInteger(2002, 2004)
	local dept = DEPTS[rng:NextInteger(1, #DEPTS)]
	if stage == 1 then
		return {
			{ text = "PURGE files dated before " .. year .. ".", test = function(f: File)
				return if f.year < year then "purge" else nil
			end },
			{ text = "KEEP everything else.", test = function(_f: File)
				return "keep"
			end },
		}
	elseif stage == 2 then
		return {
			{ text = "EXCEPTION: files tagged LEGAL HOLD are always KEPT.", test = function(f: File)
				return if f.tag == "LEGAL HOLD" then "keep" else nil
			end },
			{ text = "PURGE .bak and .tmp files.", test = function(f: File)
				return if f.ext == "bak" or f.ext == "tmp" then "purge" else nil
			end },
			{ text = "KEEP everything else.", test = function(_f: File)
				return "keep"
			end },
		}
	end
	return {
		{ text = "EXCEPTION: files dated 2006 are KEPT.", test = function(f: File)
			return if f.year == 2006 then "keep" else nil
		end },
		{ text = "PURGE files from " .. dept .. ".", test = function(f: File)
			return if f.dept == dept then "purge" else nil
		end },
		{ text = "PURGE anything tagged CONFIDENTIAL.", test = function(f: File)
			return if f.tag == "CONFIDENTIAL" then "purge" else nil
		end },
		{ text = "KEEP everything else.", test = function(_f: File)
			return "keep"
		end },
	}
end

local function classify(rules: { Rule }, f: File): string
	for _, r in rules do
		local out = r.test(f)
		if out then
			return out
		end
	end
	return "keep"
end

local FileSort = {}
FileSort.id = "FileSort"
FileSort.title = "SecureErase :: File Sorter"
FileSort.instructions = "Select a file, then send it to PURGE or KEEP. Follow the rule list top to bottom."

function FileSort.newStage(state: any)
	local rng: Random = state.rng
	local count = Config.MINIGAMES.FileSort.filesPerStage[math.min(state.stage, 3)]
	for _attempt = 1, 30 do
		local rules = ruleSet(state.stage, rng)
		local files: { File } = {}
		for i = 1, count do
			local f: File = {
				id = i,
				name = NAMES[rng:NextInteger(1, #NAMES)] .. "_" .. string.format("%02d", rng:NextInteger(1, 40)),
				ext = EXTS[rng:NextInteger(1, #EXTS)],
				year = rng:NextInteger(2000, 2006),
				dept = DEPTS[rng:NextInteger(1, #DEPTS)],
				tag = TAGS[rng:NextInteger(1, #TAGS)],
				target = "keep",
				bin = nil,
			}
			f.target = classify(rules, f)
			files[i] = f
		end
		local purge = 0
		for _, f in files do
			if f.target == "purge" then
				purge += 1
			end
		end
		if purge >= 2 and purge <= count - 1 then
			state.data.rules = rules
			state.data.files = files
			return
		end
	end
	-- fallback: guarantee both bins are used
	local rules = ruleSet(1, rng)
	local files: { File } = {}
	for i = 1, count do
		local f: File = { id = i, name = "record_" .. i, ext = "doc", year = if i % 2 == 0 then 2000 else 2006, dept = "ACCOUNTS", tag = "", target = "keep", bin = nil }
		f.target = classify(rules, f)
		files[i] = f
	end
	state.data.rules = rules
	state.data.files = files
end

function FileSort.act(state: any, action: string, a: any, b: any)
	if action ~= "sort" then
		return { ok = false, kind = "info", message = "Unknown command." }
	end
	if typeof(a) ~= "number" or (b ~= "purge" and b ~= "keep") then
		return { ok = false, kind = "info", message = "Select a file first." }
	end
	local file: File? = nil
	for _, f in state.data.files do
		if f.id == a then
			file = f
		end
	end
	if not file or file.bin then
		return { ok = false, kind = "info", message = "That file is already sorted." }
	end
	if file.target ~= b then
		return { ok = false, kind = "bad", message = "Rule check failed: " .. file.name .. "." .. file.ext .. " bounced back." }
	end
	file.bin = b
	for _, f in state.data.files do
		if not f.bin then
			return { ok = true, kind = "good", message = file.name .. "." .. file.ext .. " -> " .. string.upper(b) }
		end
	end
	return { ok = true, kind = "stageClear", message = "Folder sorted." }
end

function FileSort.view(state: any)
	local rules = {}
	for _, r in state.data.rules do
		table.insert(rules, r.text)
	end
	local files = {}
	for _, f in state.data.files do
		table.insert(files, {
			id = f.id,
			name = f.name .. "." .. f.ext,
			year = f.year,
			dept = f.dept,
			tag = f.tag,
			bin = f.bin,
		})
	end
	return { kind = "FileSort", rules = rules, files = files }
end

function FileSort.progress(state: any): number
	local done = 0
	for _, f in state.data.files do
		if f.bin then
			done += 1
		end
	end
	return done / #state.data.files
end

function FileSort.hint(state: any, level: number): (string, any?)
	if level >= 2 then
		for _, f in state.data.files do
			if not f.bin then
				return "Hint: " .. f.name .. "." .. f.ext .. " belongs in " .. string.upper(f.target) .. ".", f.id
			end
		end
	end
	return "Hint: read the rules from the top. The first rule that matches a file decides its bin.", nil
end

return FileSort
