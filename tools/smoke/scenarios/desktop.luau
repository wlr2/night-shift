--!nocheck
-- c. Desktop: open sessions with payloads shaped like Workstation.payload(),
-- dock each of the six drives, start SecureErase and drive the REAL server
-- minigame through its view by clicking buttons (seeded monkey clicks), then
-- power loss, story fragment, procedures/messenger windows, phantom window,
-- finale screens, and leaving by button, Backspace and gamepad B.
-- Every Desktop/Leave FireServer is checked against Workstation's rules.

return function(H)
	local Report, World, Server, Rt, E = H.Report, H.World, H.Server, H.Rt, H.E
	Report.begin("c", "Desktop sessions and minigames")

	local Desktop = H.clientModule("Controllers/Desktop")
	local function isOpen(): boolean?
		if Desktop and type(Desktop.isOpen) == "function" then
			return Desktop.isOpen()
		end
		return nil
	end

	local function sit()
		if not World.humanoid.Sit then
			World.seat(World.humanoid, H.seatPart)
		end
		Server.startSession()
		H.step(4)
	end

	local rng = Rt.Random.new(20261022)
	local logStart = #World.remoteLog

	-- 1. open with no drive docked
	Server.dock = nil
	Server.job = nil
	sit()
	Report.check(isOpen() == true, "Session payload (active, no drive) opens the desktop", "Desktop.isOpen() = " .. tostring(isOpen()))
	local chrome: { [any]: boolean } = {}
	for _, b in H.buttons() do
		chrome[b] = true
	end
	local nChrome = 0
	for _ in chrome do
		nChrome += 1
	end
	Report.info(string.format("%d visible buttons on the empty desktop", nChrome))

	-- 2. click every visible desktop button once (icons, taskbar, start menu,
	--    side windows and whatever they open), never the leave button
	local sawProcedures, sawMessenger = false, false
	local procLine = H.Dialogue.PROCEDURES and H.Dialogue.PROCEDURES[1]
	local clicked: { [any]: boolean } = {}
	local clicks = 0
	local function closeLike(b): boolean
		local l = string.lower(H.label(b))
		return string.find(string.lower(b.name), "close", 1, true) ~= nil or string.find(l, "%[x%]") ~= nil
	end
	for _ = 1, 4 do
		local progressed = false
		local list = H.buttons()
		-- window close buttons last, so a window's own controls get clicked first
		table.sort(list, function(a, b)
			local ca, cb = closeLike(a), closeLike(b)
			if ca ~= cb then
				return cb
			end
			return a.id < b.id
		end)
		for _, b in list do
			if clicks >= 80 then
				break
			end
			if not clicked[b] and not b.destroyed and H.isShown(b) and not H.isLeaveButton(b) then
				clicked[b] = true
				clicks += 1
				progressed = true
				H.click(b)
				H.step(2)
				if procLine and H.findText(string.sub(procLine, 1, 24)) then
					sawProcedures = true
				end
				if H.findText("Skip the checksum on HD-4402") then
					sawMessenger = true
				end
			end
		end
		if not progressed then
			break
		end
	end
	Report.info(string.format("click sweep: %d buttons clicked", clicks))
	Report.check(isOpen() == true, "desktop still open after clicking every non-leave button")
	Report.check(sawProcedures, "Procedures window shows the procedures text", procLine and ("looked for: " .. string.sub(procLine, 1, 24)) or nil)
	Report.check(sawMessenger, "Messenger window shows the boss messages")
	local replies = 0
	for _, c in H.remoteCalls(logStart, "Desktop") do
		if c.args[2] == "bossReply" then
			replies += 1
			Report.check(c.args[3] == 2 and (c.args[4] == 1 or c.args[4] == 2), "bossReply targets the open question (id 2, choice 1|2)", string.format("got (%s, %s)", tostring(c.args[3]), tostring(c.args[4])))
		end
	end
	Report.check(replies >= 1, "a Messenger choice button sends bossReply")

	-- the chrome set: everything clickable before any minigame is shown
	for _, b in H.buttons() do
		chrome[b] = true
	end

	-- 3. the six drives / minigames
	local order = Server.Minigames.ORDER
	for i, gameId in order do
		local mark = #World.remoteLog
		Server.dockDrive(i, gameId)
		H.step(3)
		-- find and press the start control (any new button that sends "start")
		local started = false
		for _, b in H.buttons() do
			if not started and not chrome[b] and not H.isLeaveButton(b) then
				H.click(b)
				H.step(2)
				for _, c in H.remoteCalls(mark, "Desktop") do
					if c.args[2] == "start" then
						started = true
					end
				end
			end
		end
		if not started then
			-- maybe the start button is part of the chrome-looking set
			for _, b in H.buttons() do
				if not started and string.find(string.lower(H.label(b)), "start", 1, true) and not H.isLeaveButton(b) and not string.find(string.lower(b.name), "^start$") then
					H.click(b)
					H.step(2)
					for _, c in H.remoteCalls(mark, "Desktop") do
						if c.args[2] == "start" then
							started = true
						end
					end
				end
			end
		end
		Report.check(started, string.format("drive %d (%s): a desktop button sends 'start'", i, gameId))
		if not started then
			Server.job = Server.Minigames.newJob(gameId, false, 99 + i)
			Server.pushSession()
		end
		H.step(3)
		local gameButtons = 0
		for _, b in H.buttons() do
			if not chrome[b] then
				gameButtons += 1
			end
		end
		Report.check(gameButtons > 0, string.format("%s view renders clickable controls", gameId), string.format("%d new buttons", gameButtons))
		-- monkey clicks through the real minigame
		local before = table.clone(Server.results)
		local doneBefore = Server.completed or 0
		local acts = 0
		local maxStage = Server.job and Server.job.state.stage or 0
		for _ = 1, 140 do
			if (Server.completed or 0) > doneBefore or not Server.job then
				break
			end
			local cands = {}
			for _, b in H.buttons() do
				if not chrome[b] and not H.isLeaveButton(b) then
					table.insert(cands, b)
				end
			end
			if #cands == 0 then
				H.run(0.5)
				continue
			end
			local b = cands[rng:NextInteger(1, #cands)]
			local m2 = #World.remoteLog
			H.click(b)
			H.step(2)
			for _, c in H.remoteCalls(m2, "Desktop") do
				if c.args[2] == "act" then
					acts += 1
				end
			end
			if Server.job then
				maxStage = math.max(maxStage, Server.job.state.stage)
				if Server.job.transitionUntil > H.Sched.now then
					H.run(1.8)
				end
			end
		end
		local delta = {}
		for k, v in Server.results do
			local d = v - (before[k] or 0)
			if d > 0 then
				table.insert(delta, k .. "=" .. d)
			end
		end
		table.sort(delta)
		Report.check(acts > 0, string.format("%s: clicking the view sends 'act' commands the server accepts", gameId), string.format("%d acts, results %s, reached stage %d", acts, table.concat(delta, " "), maxStage))
		-- force a stage clear and the completion path if random clicks did not
		if Server.job and Server.job.state.stage < 2 and Server.job.state.stages >= 2 then
			local job = Server.job
			job.state.stage += 1
			job.state.mistakes = 0
			Server.Minigames.get(job.game).newStage(job.state)
			job.transitionUntil = H.Sched.now + H.Config.STAGE_TRANSITION_SECONDS
			Server.lastFeedback = { text = "Stage verified.", kind = "good" }
			Server.pushSession()
			H.step(3)
			H.run(1.8)
			Server.pushSession()
			H.step(3)
			Report.info(gameId .. ": stage 2 forced by the harness (transition + next-stage render exercised)")
		end
		if Server.job then
			Server.lastFeedback = { text = Server.dock.id .. " securely erased.", kind = "good" }
			Server.snap.erased += 1
			H.fire("Fx", "DriveErased", { id = Server.dock.id, count = Server.snap.erased })
			Server.dock = nil
			Server.job = nil
			Server.pushSession()
			Server.pushState()
			H.step(3)
		end
		Report.check(isOpen() == true, string.format("%s: desktop still open after the drive is erased", gameId))
	end

	-- 4. power loss overlay
	Server.dockDrive(1, order[1])
	Server.job = Server.Minigames.newJob(order[1], false, 5)
	Server.pushSession()
	H.step(3)
	Server.snap.power.workstation = false
	Server.snap.power.warning = true
	Server.pushState()
	Server.pushSession("power")
	H.step(3)
	Report.check(H.findText("power") ~= nil, "power loss shows a no-power message on the desktop")
	local mark = #World.remoteLog
	for _, b in H.buttons() do
		if not chrome[b] and not H.isLeaveButton(b) and H.isShown(b) then
			H.click(b)
			H.step(1)
		end
	end
	local acts = 0
	for _, c in H.remoteCalls(mark, "Desktop") do
		if c.args[2] == "act" then
			acts += 1
		end
	end
	Report.info(string.format("%d 'act' commands sent while the workstation had no power (server answers with a power refresh)", acts))
	Server.snap.power.workstation = true
	Server.snap.power.warning = false
	Server.pushState()
	Server.pushSession()
	H.step(3)
	Report.check(H.findText("has lost power") == nil and H.findText("no power") == nil, "no-power message clears when power returns")

	-- 5. story fragment window
	local frag = H.Dialogue.FRAGMENTS[3]
	H.fire("Fx", "Fragment", { index = 3 })
	H.step(3)
	Report.check(frag ~= nil and H.findText(frag.title) ~= nil, "Fragment Fx opens a window with the fragment title", frag and frag.title or nil)

	-- 6. phantom window
	mark = #World.remoteLog
	local chrome2: { [any]: boolean } = table.clone(chrome)
	for _, b in H.buttons() do
		chrome2[b] = true
	end
	Server.phantom = { id = 7, x = 0.3, y = 0.25, first = true }
	Server.pushSession()
	H.step(3)
	local phantomSent = nil
	for _, b in H.buttons() do
		if phantomSent == nil and not chrome2[b] and not H.isLeaveButton(b) and H.isShown(b) then
			H.click(b)
			H.step(2)
			for _, c in H.remoteCalls(mark, "Desktop") do
				if c.args[2] == "phantom" then
					phantomSent = c
				end
			end
		end
	end
	Report.check(phantomSent ~= nil and phantomSent.args[3] == 7, "phantom window buttons send phantom(id, choice)", if phantomSent then string.format("phantom(%s, %s)", tostring(phantomSent.args[3]), tostring(phantomSent.args[4])) else "no phantom command")
	H.step(3)

	-- 7. finale: purge queue, sign-off, clock-out
	Server.dock = nil
	Server.job = nil
	Server.snap.phase = "FinalPurge"
	Server.snap.purge = {
		{ name = "MERRIN, D. (night lead)", cancelled = false, locked = true },
		{ name = "SMOKE (you)", cancelled = false, locked = false, userId = World.player.UserId },
		{ name = "ANA", cancelled = false, locked = false, userId = 2002 },
	}
	Server.snap.purgeDeadline = 118
	Server.pushState()
	Server.pushSession()
	H.step(3)
	mark = #World.remoteLog
	for _ = 1, 3 do
		for _, b in H.buttons() do
			if not chrome[b] and not H.isLeaveButton(b) and H.isShown(b) then
				H.click(b)
				H.step(2)
			end
		end
	end
	local cancels, signStarts = 0, 0
	for _, c in H.remoteCalls(mark, "Desktop") do
		if c.args[2] == "purgeCancel" then
			cancels += 1
		elseif c.args[2] == "signOffStart" then
			signStarts += 1
		end
	end
	Report.check(cancels >= 2, "FinalPurge: CANCEL buttons send purgeCancel for the unlocked entries", string.format("%d purgeCancel", cancels))
	Report.check(signStarts >= 1, "FinalPurge: emergency sign-off button sends signOffStart once all entries are cancelled", string.format("%d signOffStart", signStarts))
	if Server.snap.phase ~= "SignOff" then
		Server.snap.phase = "SignOff"
		Server.snap.signOff = { progress = 0.33, awaiting = true, paused = false }
		Server.pushState()
		Server.pushSession()
	end
	H.step(3)
	mark = #World.remoteLog
	for _, b in H.buttons() do
		if not chrome[b] and not H.isLeaveButton(b) and H.isShown(b) then
			H.click(b)
			H.step(2)
		end
	end
	local confirms = 0
	for _, c in H.remoteCalls(mark, "Desktop") do
		if c.args[2] == "signOffConfirm" then
			confirms += 1
		end
	end
	Report.check(confirms == 1, "SignOff: the CONFIRM button sends signOffConfirm exactly once", string.format("%d signOffConfirm", confirms))
	Server.snap.phase = "ClockOut"
	Server.snap.signOff = { progress = 1, awaiting = false, paused = false }
	Server.pushState()
	Server.pushSession()
	H.step(3)
	-- back to normal play for the rest of the run
	Server.snap.phase = "Work"
	Server.snap.purge = nil
	Server.snap.purgeDeadline = nil
	Server.snap.signOff = nil
	Server.pushState()
	Server.pushSession()
	H.step(3)

	-- 8. leave by the on-screen button
	mark = #World.remoteLog
	local leaveBtn = nil
	for _, b in H.buttons() do
		if leaveBtn == nil and H.isLeaveButton(b) then
			leaveBtn = b
		end
	end
	Report.check(leaveBtn ~= nil, "a visible 'Leave computer' button exists while seated")
	if leaveBtn then
		H.click(leaveBtn)
		H.step(4)
	end
	local leaves = H.remoteCalls(mark, "Leave")
	Report.check(#leaves == 1, "Leave button fires the Leave remote once", string.format("%d Leave calls", #leaves))
	Report.check(isOpen() == false, "desktop closes after leaving")
	Report.check(World.humanoid.Sit == false, "humanoid is standing after leaving")

	-- 9. leave with Backspace (keyboard) and ButtonB (gamepad)
	for _, key in { E.KeyCode.Backspace, E.KeyCode.ButtonB } do
		sit()
		mark = #World.remoteLog
		World.pressKey(key, if key == E.KeyCode.ButtonB then E.UserInputType.Gamepad1 else E.UserInputType.Keyboard)
		H.step(4)
		Report.check(#H.remoteCalls(mark, "Leave") == 1 and isOpen() == false, "pressing " .. key.Name .. " while seated leaves the computer", string.format("%d Leave calls, open=%s", #H.remoteCalls(mark, "Leave"), tostring(isOpen())))
	end
	-- 10. Space: the humanoid jumps out of the seat before the server answers
	sit()
	World.unseat(World.humanoid)
	H.step(2)
	Report.check(isOpen() == false, "jumping out of the seat (Space) closes the desktop at once")
	Server.endSession("stood up")
	H.step(3)
	-- 11. Backspace while walking must not fire Leave (action unbound)
	mark = #World.remoteLog
	World.pressKey(E.KeyCode.Backspace)
	H.step(2)
	Report.check(#H.remoteCalls(mark, "Leave") == 0, "Backspace while walking does nothing (leave action unbound)")

	-- FireServer sanity over the whole scenario
	local bad = {}
	for _, s in Server.issues do
		table.insert(bad, s)
	end
	for _, c in H.remoteCalls(logStart) do
		for _, iss in c.issues do
			table.insert(bad, c.remote .. " @ " .. c.site .. ": " .. iss)
		end
	end
	local n = #H.remoteCalls(logStart, "Desktop")
	Report.check(#bad == 0, string.format("all %d Desktop FireServer calls pass Workstation's validation (session id, kind, arg types)", n), if #bad > 0 then table.concat(bad, "\n") else nil)
	if #Server.payloadIssues > 0 then
		Report.warn("server->client payload serialisation", table.concat(Server.payloadIssues, "\n"))
	end
	local kinds = {}
	for k, v in Server.commands do
		table.insert(kinds, k .. "=" .. v)
	end
	table.sort(kinds)
	Report.info("server commands seen: " .. table.concat(kinds, " "))
end
