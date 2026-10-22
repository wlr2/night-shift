--!nocheck
-- b. HUD / State: realistic snapshots (threats, team, objective, pager),
-- Notify toasts, every Fx cue the server can send (found by scanning
-- src/server for fx("Name", ...)), carry / downed attributes and pings.

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local V3 = roblox.Vector3

-- Plausible data per cue, shaped like the server call sites.
local function cueData(H, name: string): (boolean, any)
	local D = H.Dialogue
	local me = H.World.player
	local data = {
		BossMessage = { id = 41, from = "R. Kessler", text = "Bring me the ACCOUNTS printout before you erase anything else.", kind = "request" },
		BreakerReset = { id = "MAIN" },
		ChairShift = { pos = V3.new(-5.6, 1, 2.6) },
		ChaseStart = { target = me.UserId, headStart = 3 },
		CheckpointSaved = { label = "Drive HD-2203 erased" },
		ClockOutStart = nil,
		ClockedOut = { name = "Ana" },
		CrewSeen = nil,
		DesktopSound = { kind = "bad" },
		DoorKnock = nil,
		DoorLatched = nil,
		DoorOpened = nil,
		DoorUnlatched = nil,
		Downed = { name = "Ben", cause = "figure" },
		DriveDocked = { id = "HD-3318" },
		DriveErased = { id = "HD-3318", count = 3 },
		Ending = { title = D.ENDING and D.ENDING.title or "CLOCKED OUT", lines = D.ENDING and D.ENDING.lines or { "line" }, minutes = 21, seconds = 7 },
		Escaped = { name = me.DisplayName },
		FigureApproach = nil,
		FigureInside = { finale = true },
		FigurePeek = { where = "Kitchenette" },
		FinalPurge = nil,
		FootstepsStop = { pos = V3.new(-4, 0, 6) },
		Fragment = { index = 3 },
		FrontDoorOpen = nil,
		FrontKnock = nil,
		LightFlicker = { seconds = 1.6 },
		MonitorWake = { desk = 3, text = "WHO IS STILL HERE" },
		PcShutdown = { desk = 2 },
		PhoneRing = { pos = V3.new(21.1, 3.2, -12.4) },
		PowerOff = { ids = { "LIGHTS" } },
		PowerWarning = { seconds = 4 },
		PrinterWake = nil,
		PurgeExecuted = nil,
		Restore = { reason = "Everyone was caught." },
		Revived = { name = "Ben", by = me.DisplayName },
		SignOffConfirm = { at = 50 },
		SignOffStart = nil,
		TeamCaught = { solo = false, delay = 3.5 },
		TrashThrown = nil,
	}
	local known = false
	for k in pairs(data) do
		if k == name then
			known = true
		end
	end
	-- nil-data cues are listed above as nil values, so check the source list too
	local nilCues = { ClockOutStart = 1, CrewSeen = 1, DoorKnock = 1, DoorLatched = 1, DoorOpened = 1, DoorUnlatched = 1, FigureApproach = 1, FinalPurge = 1, FrontDoorOpen = 1, FrontKnock = 1, PrinterWake = 1, PurgeExecuted = 1, SignOffStart = 1, TrashThrown = 1 }
	if nilCues[name] then
		known = true
	end
	return known, data[name]
end

-- every cue name the server sends: GameState.fx("Name", ...) and the
-- conditional forms (if x then "A" else "B")
local function serverCues(root: string): { string }
	local found, list = {}, {}
	local function scan(dir: string)
		for _, e in fs.readDir(dir) do
			local p = dir .. "/" .. e
			if fs.isDir(p) then
				scan(p)
			elseif string.match(e, "%.luau$") then
				for line in string.gmatch(fs.readFile(p), "[^\n]+") do
					local i = string.find(line, "fx(", 1, true)
					if i and not string.find(line, "function", 1, true) then
						local rest = string.sub(line, i + 3)
						local depth, stop = 1, #rest
						for j = 1, #rest do
							local ch = string.sub(rest, j, j)
							if ch == "(" or ch == "{" then
								depth += 1
							elseif ch == ")" or ch == "}" then
								depth -= 1
							elseif ch == "," and depth == 1 then
								stop = j - 1
								break
							end
							if depth == 0 then
								stop = j - 1
								break
							end
						end
						local head = string.sub(rest, 1, stop)
						for pos, name in string.gmatch(head, '()"([A-Z][%w_]*)"') do
							local before = string.sub(head, math.max(1, pos - 4), pos - 1)
							if not string.find(before, "==", 1, true) and not found[name] then
								found[name] = true
								table.insert(list, name)
							end
						end
					end
				end
			end
		end
	end
	scan(root .. "/src/server")
	table.sort(list)
	return list
end

return function(H)
	local Report, World, Server, Rt = H.Report, H.World, H.Server, H.Rt
	Report.begin("b", "HUD / State / Notify / Fx")

	local snap = Server.snap
	Server.pushState()
	H.step(3)

	Report.check(H.findText(snap.objective) ~= nil, "objective text from the State snapshot is on screen", "objective: " .. snap.objective)
	local missingThreats = {}
	for _, t in snap.threats do
		if not H.findText(t.label) then
			table.insert(missingThreats, t.label)
		end
	end
	Report.check(#missingThreats == 0, string.format("all %d threats from the snapshot are on screen", #snap.threats), if #missingThreats > 0 then "missing: " .. table.concat(missingThreats, "; ") else nil)
	local missingTeam = {}
	for _, p in World.services.Players:GetPlayers() do
		if not H.findText(p.DisplayName) then
			table.insert(missingTeam, p.DisplayName)
		end
	end
	Report.check(#missingTeam == 0, "every player's name is on screen (team list)", if #missingTeam > 0 then "missing: " .. table.concat(missingTeam, ", ") .. "\nvisible text: " .. string.sub(H.allText(), 1, 400) else nil)

	-- threats update: one removed, one added
	table.remove(snap.threats, 1)
	table.insert(snap.threats, { id = "power", label = "Power failure: office lights", urgent = true, where = "Breaker panel" })
	Server.pushState()
	H.step(3)
	Report.check(H.findText("Power failure: office lights") ~= nil and H.findText("Rear door is unlatched") == nil, "threat list follows snapshot changes (add + remove)")

	-- toasts
	for _, k in { "good", "bad", "info" } do
		H.fire("Notify", "Smoke toast " .. k .. ": the quick brown fox jumps over the lazy dog", k)
	end
	H.step(3)
	local shown = 0
	for _, k in { "good", "bad", "info" } do
		if H.findText("Smoke toast " .. k) then
			shown += 1
		end
	end
	Report.check(shown == 3, "Notify toasts (good / bad / info) are on screen", string.format("%d of 3 visible", shown))
	H.run(12)
	local lingering = 0
	for _, k in { "good", "bad", "info" } do
		if H.findText("Smoke toast " .. k) then
			lingering += 1
		end
	end
	Report.check(lingering == 0, "toasts expire (none visible 12 s later)", if lingering > 0 then lingering .. " still visible" else nil)
	-- burst: the stack must stay bounded
	for i = 1, 9 do
		H.fire("Notify", "Burst toast " .. i, "info")
	end
	H.step(3)
	local burst = 0
	for i = 1, 9 do
		if H.findText("Burst toast " .. i) then
			burst += 1
		end
	end
	Report.check(burst <= 6, "a burst of 9 toasts is trimmed on screen", string.format("%d visible", burst))
	H.run(12)

	-- every server Fx cue
	local cues = serverCues(H.Loader.root)
	local unknown = {}
	local before = #Report.current.errors
	for _, name in cues do
		local known, data = cueData(H, name)
		if not known then
			table.insert(unknown, name)
		end
		H.fire("Fx", name, data)
		H.step(2)
	end
	H.run(2)
	Report.check(#Report.current.errors == before, string.format("all %d server Fx cues handled without Lua errors", #cues))
	Report.info("Fx cues sent: " .. table.concat(cues, ", "))
	if #unknown > 0 then
		Report.warn("Fx cues with no plausible data in the harness (sent nil)", table.concat(unknown, ", "))
	end
	-- the pager line from BossMessage should have been visible as a toast
	H.fire("Fx", "BossMessage", { id = 42, from = "R. Kessler", text = "Pager smoke line: where is the ledger?", kind = "info" })
	H.step(3)
	Report.check(H.findText("Pager smoke line") ~= nil, "BossMessage Fx shows a pager toast while walking")
	-- let the ending card run its course
	H.run(32)
	local endingTitle = H.Dialogue.ENDING and H.Dialogue.ENDING.title
	if endingTitle then
		Report.check(H.findText(endingTitle) == nil, "ending card clears after Config.PHASE.endingSeconds")
	end

	-- carrying / downed attributes
	World.player:SetAttribute("Carrying", "HD-3318")
	H.step(3)
	Report.check(H.findText("HD-3318") ~= nil, "Carrying attribute shows a carry hint naming the item")
	World.player:SetAttribute("Carrying", nil)
	H.step(3)
	World.player:SetAttribute("Downed", true)
	H.step(3)
	Report.check(H.findText("caught") ~= nil, "Downed attribute shows the downed overlay")
	World.player:SetAttribute("Downed", nil)
	H.step(3)
	Report.check(H.findText("You were caught") == nil, "downed overlay hides again")

	-- pings: remote broadcast and the G key
	H.fire("Ping", V3.new(-4, 0.5, 6), "Ana", "Office")
	H.step(2)
	local bb = 0
	Rt.eachDescendant(Rt.rec(World.workspace), function(d)
		if d.class == "BillboardGui" then
			bb += 1
		end
	end)
	Report.check(bb > 0, "Ping broadcast creates a world marker (BillboardGui)")
	H.run(8)
	local mark = #World.remoteLog
	-- look down at the floor so the emulated raycast hits
	World.camera.CFrame = H.Rt.lookAt(V3.new(12, 4.5, 9), V3.new(12, 0, 4))
	World.pressKey(H.E.KeyCode.G)
	H.step(2)
	local pings = H.remoteCalls(mark, "Ping")
	Report.check(#pings == 1, "pressing G sends one Ping to the server", string.format("%d Ping calls", #pings))
	World.pressKey(H.E.KeyCode.G)
	H.step(2)
	Report.check(#H.remoteCalls(mark, "Ping") == 1, "ping is rate limited on the client (second G within 1.5 s ignored)")
	H.run(2)
end
