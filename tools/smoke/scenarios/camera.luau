--!nocheck
-- e. Camera / cursor state machine. After every transition the harness
-- steps frames (with the default-camera-script stand-in fighting for the
-- mouse) and records CameraType, Player.CameraMode, MouseBehavior,
-- MouseIconEnabled and Cursor.isFree(). Walking must be LockCenter + hidden
-- icon; seated must be Default + visible icon; nothing may stick.

return function(H)
	local Report, World, Server, Rt, E = H.Report, H.World, H.Server, H.Rt, H.E
	Report.begin("e", "camera / cursor transitions")

	local Cursor = H.clientModule("Ui/Cursor")
	local lines = {}

	local function expect(label: string, seated: boolean)
		H.step(20)
		local s = H.camState()
		table.insert(lines, string.format("%-46s %s", label, H.fmtCam(s)))
		local okMouse, okIcon, okCam
		if seated then
			okMouse = s.mouse == tostring(E.MouseBehavior.Default)
			okIcon = s.icon == true
			okCam = s.cameraType == tostring(E.CameraType.Scriptable)
		else
			okMouse = s.mouse == tostring(E.MouseBehavior.LockCenter)
			okIcon = s.icon == false
			okCam = s.cameraType == tostring(E.CameraType.Custom)
		end
		local okMode = s.cameraMode == tostring(E.CameraMode.LockFirstPerson)
		local okCursor = s.cursorFree == nil or s.cursorFree == seated
		Report.check(okMouse and okIcon and okCam and okMode and okCursor, string.format("%s -> %s", label, if seated then "seated (Default, icon on, Scriptable)" else "walking (LockCenter, icon off, Custom, LockFirstPerson)"), H.fmtCam(s))
		return s
	end

	local function sit()
		World.seat(World.humanoid, H.seatPart)
		Server.startSession()
	end

	-- make sure we start walking with a live character
	if World.humanoid.Sit then
		World.unseat(World.humanoid)
	end
	Server.endSession("reset")
	expect("idle walking", false)

	sit()
	expect("sit + Session active", true)

	-- leave by button path: client sets Sit=false first, server answers
	local Desktop = H.clientModule("Controllers/Desktop")
	if Desktop and type(Desktop.leave) == "function" then
		H.Sched.spawn(Desktop.leave)
		H.step(1)
		expect("Desktop.leave() (before the server answers)", false)
		H.step(3)
		expect("server Session inactive after Leave", false)
	end

	sit()
	expect("sit again", true)
	Server.endSession("round reset")
	World.unseat(World.humanoid)
	expect("server ends the session (kick / round reset)", false)

	-- the server ends the session but the client is still seated for a moment
	sit()
	expect("sit", true)
	Server.endSession("power")
	H.step(1)
	local s1 = H.camState()
	table.insert(lines, string.format("%-46s %s", "Session inactive while still seated (1 frame)", H.fmtCam(s1)))
	World.unseat(World.humanoid)
	expect("then the server stands the humanoid up", false)

	-- death while seated, then respawn
	sit()
	expect("sit before death", true)
	World.kill()
	H.step(2)
	expect("humanoid died while seated", false)
	World.respawn()
	expect("respawned character", false)
	Report.check(World.camera.CameraSubject == World.humanoid, "camera subject is the new humanoid after respawn")

	-- respawn while seated without a death (LoadCharacter / reset)
	sit()
	expect("sit", true)
	World.respawn()
	H.step(2)
	Server.endSession("operator lost")
	expect("character replaced while seated", false)

	-- stale active session payload after standing up must not re-capture
	sit()
	expect("sit", true)
	World.unseat(World.humanoid)
	H.step(1)
	Server.pushSession()
	H.step(20)
	local st = H.camState()
	table.insert(lines, string.format("%-46s %s", "Session(active) arriving after standing up", H.fmtCam(st)))
	if st.desktopOpen or st.cameraType == tostring(E.CameraType.Scriptable) then
		Report.warn("an active Session payload that arrives after the player stood up re-opens the desktop and seated camera until the server's inactive payload arrives", "Desktop and WorkstationCamera act on payload.active without checking that the humanoid is seated. Transient in practice (the server sends active=false when the seat Occupant clears), but the player briefly sees the desktop again while standing.\n" .. H.fmtCam(st))
	end
	Server.endSession("stood up")
	expect("server catches up", false)

	-- other Cursor reasons (ending card, menus) while walking
	if Cursor and type(Cursor.request) == "function" then
		H.Sched.spawn(Cursor.request, "smoke", true)
		H.step(20)
		local s = H.camState()
		table.insert(lines, string.format("%-46s %s", "Cursor.request('smoke', true) while walking", H.fmtCam(s)))
		local applied = s.mouse == tostring(E.MouseBehavior.Default) and s.icon == true
		-- is anything in the game asking for the cursor besides the desktop?
		-- callers other than the desktop (which is covered by the Session path)
		local users = {}
		Rt.eachDescendant(Rt.rec(H.clientRoot), function(d)
			if d.class == "ModuleScript" and d.name ~= "Desktop" and d.name ~= "Cursor" then
				local src = d.sourceText or ""
				if string.find(src, "Cursor.request", 1, true) then
					table.insert(users, d.name)
				end
			end
		end)
		local camSrc = Rt.rec(H.clientRoot.Controllers.WorkstationCamera).sourceText or ""
		local camUsesCursor = string.find(camSrc, "Cursor", 1, true) ~= nil
		if applied then
			Report.check(true, "a non-desktop Cursor.request frees the mouse while walking")
		elseif #users > 0 then
			Report.check(false, "a non-desktop Cursor.request frees the mouse while walking", string.format("Cursor.request is called by %s, but WorkstationCamera %s; the pointer stays locked:\n%s", table.concat(users, ", "), if camUsesCursor then "does not apply it while walking" else "never reads Cursor", H.fmtCam(s)))
		else
			Report.warn("Cursor contract not applied while walking: Cursor.request(reason, true) leaves the mouse locked", string.format("WorkstationCamera %s. Only the Desktop calls Cursor.request today and its path works through Session, so nothing is broken yet; an ending card or menu that relies on Cursor.lua's contract would get no pointer.\n%s", if camUsesCursor then "reads Cursor but does not apply it while walking" else "never reads Cursor", H.fmtCam(s)))
		end
		H.Sched.spawn(Cursor.request, "smoke", false)
		expect("Cursor.request('smoke', false)", false)
		-- desktop reason must win over other reasons going away
		sit()
		H.Sched.spawn(Cursor.request, "smoke", true)
		H.step(2)
		H.Sched.spawn(Cursor.request, "smoke", false)
		expect("seated, unrelated reason released", true)
		Server.endSession("stood up")
		World.unseat(World.humanoid)
		expect("stand", false)
	else
		Report.warn("Ui/Cursor module not loaded; cursor contract not checked")
	end

	-- Roblox menu opened and closed while walking: the icon must hide again
	local gs = World.services.GuiService
	Rt.setInternal(gs, "MenuIsOpen", true)
	Rt.fire(Rt.getSignal(gs, "MenuOpened"))
	H.step(10)
	table.insert(lines, string.format("%-46s %s", "Roblox menu open while walking", H.fmtCam(H.camState())))
	Rt.setInternal(gs, "MenuIsOpen", false)
	Rt.fire(Rt.getSignal(gs, "MenuClosed"))
	expect("Roblox menu closed again", false)

	-- Roblox menu opened while seated then closed: icon must come back
	sit()
	expect("sit", true)
	local uis = World.services.UserInputService
	uis.MouseIconEnabled = false -- something (core menu, another script) hides it
	expect("icon hidden by someone else while seated (re-asserted)", true)
	Server.endSession("stood up")
	World.unseat(World.humanoid)
	expect("final stand", false)

	Report.info("state log:\n         " .. table.concat(lines, "\n         "))
end
