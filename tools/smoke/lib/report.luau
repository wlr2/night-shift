--!nocheck
-- Collects scenario results, Luau errors (with game file:line), warnings and
-- prints the summary.

local Report = {}

Report.scenarios = {} :: { any }
Report.current = nil :: any
Report.verbose = false
Report.global = { errors = {}, warns = {}, prints = {}, notes = {} }

local function bucket(): any
	return Report.current or Report.global
end

function Report.begin(id: string, title: string)
	local s = { id = id, title = title, checks = {}, errors = {}, warns = {}, prints = {}, info = {}, status = "PASS" }
	table.insert(Report.scenarios, s)
	Report.current = s
	return s
end

function Report.finish()
	local s = Report.current
	if not s then
		return
	end
	for _, c in s.checks do
		if c.status == "FAIL" then
			s.status = "FAIL"
		elseif c.status == "WARN" and s.status == "PASS" then
			s.status = "WARN"
		end
	end
	for _, e in s.errors do
		if e.origin == "game" then
			s.status = "FAIL"
		elseif s.status == "PASS" then
			s.status = "WARN"
		end
	end
	Report.current = nil
end

function Report.check(ok: boolean, label: string, detail: string?)
	local s = bucket()
	table.insert(s.checks or Report.global.notes, { status = if ok then "PASS" else "FAIL", label = label, detail = detail })
	return ok
end

function Report.warn(label: string, detail: string?)
	local s = bucket()
	table.insert(s.checks or Report.global.notes, { status = "WARN", label = label, detail = detail })
end

function Report.info(text: string)
	local s = bucket()
	table.insert(s.info or Report.global.notes, text)
end

-- the first src/ location in a message or traceback
function Report.site(msg: string, tb: string?): string?
	local s = string.match(msg, "(src/[%w_/%.%-]+%.luau?:%d+)")
	if s then
		return s
	end
	if tb then
		s = string.match(tb, "(src/[%w_/%.%-]+%.luau?:%d+)")
	end
	return s
end

function Report.error(msg: string, tb: string, kind: string)
	local site = Report.site(msg, tb)
	local origin = "harness"
	if site then
		origin = "game"
	end
	-- raised inside harness code (a mock bug), even if game frames are below it
	local head = string.match(msg, "^(.-):%d+:")
	if head and string.find(head, "tools/smoke/", 1, true) then
		origin = "harness"
		site = head .. " (via " .. tostring(site) .. ")"
	end
	-- errors raised inside harness code but attributed through game frames
	local first = string.match(tb or "", "^%s*([^\n]+)")
	local e = { msg = msg, tb = tb, kind = kind, site = site, origin = origin, first = first }
	local b = bucket()
	for _, x in b.errors do
		if x.msg == msg then
			x.count = (x.count or 1) + 1
			return
		end
	end
	table.insert(b.errors, e)
end

-- warn() output; known error-reporting patterns become errors
function Report.gameWarn(text: string, site: string)
	if string.find(text, "handler error", 1, true) or string.find(text, "^%[Effects%]") or string.find(text, "Infinite yield", 1, true) then
		local s = Report.site(text) or site
		local b = bucket()
		for _, x in b.errors do
			if x.msg == text then
				x.count = (x.count or 1) + 1
				return
			end
		end
		table.insert(b.errors, { msg = text, tb = "", kind = "warn()", site = s, origin = "game" })
		return
	end
	local b = bucket()
	for _, x in b.warns do
		if x.text == text then
			x.count = (x.count or 1) + 1
			return
		end
	end
	table.insert(b.warns, { text = text, site = site })
end

function Report.gamePrint(text: string, site: string)
	table.insert(bucket().prints, { text = text, site = site })
end

local function pad(s: string, n: number): string
	if #s >= n then
		return s
	end
	return s .. string.rep(" ", n - #s)
end

function Report.render(): (string, number)
	local out = {}
	local function line(s: string?)
		table.insert(out, s or "")
	end
	local fails = 0
	line("NIGHT SHIFT client smoke harness (Lune; not Roblox - see tools/smoke/README.md)")
	line(string.rep("=", 78))
	for _, s in Report.scenarios do
		local nf, nw, np = 0, 0, 0
		for _, c in s.checks do
			if c.status == "FAIL" then
				nf += 1
			elseif c.status == "WARN" then
				nw += 1
			else
				np += 1
			end
		end
		local errs = #s.errors
		line(string.format("%s  %s  (%d pass, %d fail, %d warn, %d lua errors)", pad(s.status, 4), pad(s.id .. " " .. s.title, 44), np, nf, nw, errs))
		if s.status == "FAIL" then
			fails += 1
		end
	end
	line(string.rep("=", 78))
	for _, s in Report.scenarios do
		line("")
		line(string.format("[%s] %s - %s", s.status, s.id, s.title))
		for _, c in s.checks do
			if c.status ~= "PASS" or Report.verbose then
				line(string.format("  %s %s%s", pad(c.status, 4), c.label, if c.detail then "\n         " .. string.gsub(c.detail, "\n", "\n         ") else ""))
			end
		end
		if not Report.verbose then
			local np = 0
			for _, c in s.checks do
				if c.status == "PASS" then
					np += 1
				end
			end
			if np > 0 then
				line(string.format("  PASS x%d (use --verbose to list)", np))
			end
		end
		for _, e in s.errors do
			line(string.format("  ERROR(%s%s) %s%s", e.origin, if e.site then " @ " .. e.site else "", e.msg, if e.count and e.count > 1 then string.format("  [x%d]", e.count) else ""))
			if Report.verbose and e.tb and e.tb ~= "" then
				line("         " .. string.gsub(e.tb, "\n", "\n         "))
			end
		end
		for _, w in s.warns do
			line(string.format("  warn() %s  (%s)%s", w.text, w.site, if w.count and w.count > 1 then string.format("  [x%d]", w.count) else ""))
		end
		for _, i in s.info do
			line("  info  " .. i)
		end
		if Report.verbose then
			for _, p in s.prints do
				line("  print " .. p.text .. "  (" .. p.site .. ")")
			end
		end
	end
	local g = Report.global
	if #g.errors > 0 or #g.warns > 0 then
		line("")
		line("[outside scenarios]")
		for _, e in g.errors do
			line(string.format("  ERROR(%s%s) %s", e.origin, if e.site then " @ " .. e.site else "", e.msg))
		end
		for _, w in g.warns do
			line(string.format("  warn() %s  (%s)", w.text, w.site))
		end
	end
	return table.concat(out, "\n"), fails
end

return Report
