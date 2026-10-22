--!nocheck
-- NIGHT SHIFT client smoke harness entry point.
-- Usage: lune run tools/smoke/main.luau [--verbose] [--only=a,b,...] [--no-editables] [--no-camera-scripts] [--root=PATH]
-- (tools/smoke/run.sh wraps this). Exit code 1 when any scenario FAILs.

local fs = require("@lune/fs")
local process = require("@lune/process")

local H = require("./lib/harness")
local Report = H.Report
local World = H.World

local args = {}
for _, a in process.args do
	if a ~= "--" then
		local k, v = string.match(a, "^%-%-([%w%-]+)=(.*)$")
		if k then
			args[k] = v
		else
			k = string.match(a, "^%-%-([%w%-]+)$")
			if k then
				args[k] = true
			end
		end
	end
end

local root = args.root or process.cwd
root = string.gsub(root, "/$", "")
if not fs.isFile(root .. "/default.project.json") then
	print("smoke: default.project.json not found under " .. root .. " (run from the repo root or pass --root=)")
	process.exit(2)
end

Report.verbose = args.verbose == true
World.opts.editables = args["no-editables"] ~= true
World.opts.cameraScripts = args["no-camera-scripts"] ~= true

local only: { [string]: boolean }? = nil
if type(args.only) == "string" then
	only = {}
	for id in string.gmatch(args.only, "[^,]+") do
		only[id] = true
	end
end

-- the API index ships with the harness; --root may point at another checkout
local apiPath = root .. "/tools/smoke/api_members.json"
if not fs.isFile(apiPath) then
	apiPath = string.gsub(process.cwd, "/$", "") .. "/tools/smoke/api_members.json"
end
local ok, err = pcall(H.setup, root, apiPath)
if not ok then
	print("smoke: harness setup failed: " .. tostring(err))
	process.exit(3)
end

local SCENARIOS = {
	{ "0", "selfcheck", require("./scenarios/selfcheck") },
	{ "a", "boot", require("./scenarios/boot") },
	{ "b", "hud", require("./scenarios/hud") },
	{ "c", "desktop", require("./scenarios/desktop") },
	{ "d", "prompts", require("./scenarios/prompts") },
	{ "e", "camera", require("./scenarios/camera") },
	{ "f", "legibility", require("./scenarios/legibility") },
}

local t0 = os.clock()
local layoutTime = 0
if args.profile then
	local orig = H.Layout.pass
	H.Layout.pass = function(pg)
		local t = os.clock()
		local n = orig(pg)
		layoutTime += os.clock() - t
		return n
	end
end
for _, sc in SCENARIOS do
	local id, name, fn = sc[1], sc[2], sc[3]
	-- the self-check and boot always run: every later scenario needs the client
	if only and not only[id] and not only[name] and id ~= "a" and id ~= "0" then
		continue
	end
	World.scenario = id
	local okRun, errRun = pcall(fn, H)
	if not okRun then
		if not Report.current then
			Report.begin(id, name)
		end
		Report.error("scenario aborted: " .. tostring(errRun), debug.traceback(), "scenario")
		local cur = Report.current
		if cur then
			-- an abort is always a failure of the run, whoever caused it
			table.insert(cur.checks, { status = "FAIL", label = "scenario ran to completion", detail = tostring(errRun) })
		end
	end
	if Report.current then
		Report.finish()
	end
end

local text, fails = Report.render()
print(text)
if #H.harnessNotes > 0 then
	print("")
	print(string.format("harness notes (%d; emulation gaps, not game bugs):", #H.harnessNotes))
	local shown = 0
	for _, n in H.harnessNotes do
		if Report.verbose or shown < 12 then
			print("  - " .. n)
			shown += 1
		end
	end
	if shown < #H.harnessNotes then
		print(string.format("  ... %d more (--verbose)", #H.harnessNotes - shown))
	end
end
print("")
print(string.format("virtual time %.1fs, %d frames, %d layout passes, %d modules required, real time %.1fs", H.Sched.now, H.Sched.frame, World.layoutPasses, H.Loader.requireCount, os.clock() - t0))
if args.profile then
	print(string.format("profile: layout %.2fs", layoutTime))
end
process.exit(if fails > 0 then 1 else 0)
