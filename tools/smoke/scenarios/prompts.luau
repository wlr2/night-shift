--!nocheck
-- d. PromptUi: ProximityPrompts built by the REAL server factory
-- (src/server/Util/Prompts.luau) on parts in front of the camera. Which
-- prompts Roblox shows is decided by the harness's prompt-engine stand-in
-- (reach from the HumanoidRootPart, on screen, Exclusivity, PromptShown /
-- PromptHidden), so PromptUi's own targeting (e.g. zeroing the reach of
-- prompts it does not target) is exercised as in Roblox. Checks: exactly one
-- card, the key press fires what the card shows, hold timing, input types,
-- touch, desktop open, phone viewport, turning away, prompt removal.

local roblox = require("@lune/roblox")
local V3, CF = roblox.Vector3, roblox.CFrame

return function(H)
	local Report, World, Server, Rt, E, Layout = H.Report, H.World, H.Server, H.Rt, H.E, H.Layout
	Report.begin("d", "PromptUi cards")

	local Prompts = nil
	local util = H.serverRoot:FindFirstChild("Util")
	local okReq, errReq = pcall(function()
		Prompts = H.Loader.require(util:FindFirstChild("Prompts"))
	end)
	Report.check(okReq and Prompts ~= nil, "server prompt factory src/server/Util/Prompts.luau loads", if okReq then nil else tostring(errReq))

	-- stand at spawn looking north (-Z); the camera follows the head
	World.setInputType("keyboard")
	World.respawn()
	H.step(3)
	local root = World.character:FindFirstChild("HumanoidRootPart")
	local eye = root.Position + V3.new(0, 1.5, 0)
	-- with --no-camera-scripts nothing moves the camera: put it in the head
	local function aim()
		if not World.opts.cameraScripts then
			World.camera.CFrame = World.character:FindFirstChild("Head").CFrame
		end
	end
	aim()

	local holder = Rt.newInstance("Folder", { name = "SmokePrompts" })
	holder.Parent = World.workspace
	local styleAtCreation = {}
	local function promptAt(offset, opts)
		local part = Rt.newInstance("Part", { name = "PromptPart_" .. opts.action })
		part.Anchored = true
		part.Size = V3.new(1, 1, 1)
		local pos = eye + offset
		part.CFrame = CF.new(pos.X, pos.Y, pos.Z)
		part.Parent = holder
		local prompt
		if Prompts then
			prompt = Prompts.make(part, opts)
		else
			prompt = Rt.createInstance("ProximityPrompt")
			prompt.ActionText = opts.action
			prompt.ObjectText = opts.object or ""
			prompt.HoldDuration = opts.hold or 0
			prompt.Parent = part
		end
		styleAtCreation[prompt] = prompt.Style
		return prompt
	end
	local collect = promptAt(V3.new(0.4, -1, -4), { action = "Collect drive", object = "HD-3318", distance = 7 })
	local dock = promptAt(V3.new(-2, -1, -6), { action = "Dock drive", object = "Workstation dock", hold = 0.5, distance = 8 })
	local sit = promptAt(V3.new(3, -1, -7), { action = "Use workstation", object = "Corner workstation", hold = 0.2, key = E.KeyCode.F, gamepad = E.KeyCode.ButtonY, distance = 9 })
	local help = promptAt(V3.new(0, -1, -2.5), { action = "Help up", object = "Smoke", hold = 2.5 })
	help:SetAttribute("OwnerUserId", World.player.UserId)
	local all = { collect, dock, sit, help }
	local actions = { "Collect drive", "Dock drive", "Use workstation", "Help up" }
	H.step(10)

	-- Roblox draws its own UI for every prompt whose Style is not Custom
	local serverDefault, runtimeDefault = {}, {}
	for _, p in all do
		if styleAtCreation[p] ~= E.ProximityPromptStyle.Custom then
			table.insert(serverDefault, p.ActionText)
		end
		if p.Style ~= E.ProximityPromptStyle.Custom then
			table.insert(runtimeDefault, p.ActionText)
		end
	end
	Report.check(#runtimeDefault == 0, "every prompt is Style = Custom on the client (Roblox's default prompt UI never draws next to the card)", if #runtimeDefault > 0 then "Style is Default on: " .. table.concat(runtimeDefault, ", ") else nil)
	if #serverDefault > 0 and #runtimeDefault == 0 then
		Report.info("Prompts.make leaves Style Default; PromptUi switches it to Custom when it registers the prompt")
	end

	local function cards(): ({ any }, { string })
		local tops, seen, labels = {}, {}, {}
		for _, t in H.texts() do
			local text = Layout.labelText(t)
			for _, a in actions do
				if text == a then
					local cur = t
					while cur.parent and Rt.rec(cur.parent).class ~= "ScreenGui" do
						cur = Rt.rec(cur.parent)
					end
					if not seen[cur] then
						seen[cur] = true
						table.insert(tops, cur)
					end
					table.insert(labels, a)
				end
			end
		end
		return tops, labels
	end
	local function inViewport(r): boolean
		local L = r.layout
		return L and L.x >= -1 and L.y >= -1 and L.x + L.w <= Layout.viewport.w + 1 and L.y + L.h <= Layout.viewport.h + 1
	end
	local function rectOf(r): string
		local L = r.layout
		return string.format("card at %.0f,%.0f size %.0fx%.0f in %dx%d", L.x, L.y, L.w, L.h, Layout.viewport.w, Layout.viewport.h)
	end
	local function triggers(): any
		local counts = {}
		local conns = {}
		for _, p in all do
			counts[p] = 0
			table.insert(conns, Rt.getSignal(p, "Triggered"):Connect(function()
				counts[p] += 1
			end))
		end
		return counts, function()
			for _, c in conns do
				c:Disconnect()
			end
		end
	end
	local function primaryLabel(): string?
		local tps, labels = cards()
		return labels[1], tps[1]
	end

	local shown = 0
	for _ in World.promptsShown do
		shown += 1
	end
	Report.info(string.format("prompt engine: %d prompt(s) shown by the engine stand-in after PromptUi's targeting", shown))
	local tops, labels = cards()
	Report.check(#tops == 1, "exactly one prompt card with 4 prompts in reach", string.format("%d cards; labels: %s", #tops, table.concat(labels, ", ")))
	Report.check(labels[1] == "Collect drive", "the prompt straight ahead (Collect drive) is the card's primary row", "rows: " .. table.concat(labels, ", "))
	Report.check(table.find(labels, "Help up") == nil, "own 'Help up' prompt (OwnerUserId = me) is never on the card")
	if tops[1] then
		Report.check(inViewport(tops[1]), "prompt card is inside the viewport", rectOf(tops[1]))
	end
	Report.check(H.findText("E") ~= nil, "keyboard keycap shows E")

	-- the key fires exactly what the card shows
	local counts, done = triggers()
	World.pressKey(E.KeyCode.E)
	H.step(3)
	local fired = {}
	for _, p in all do
		if counts[p] > 0 then
			table.insert(fired, p.ActionText .. " x" .. counts[p])
		end
	end
	Report.check(counts[collect] == 1 and #fired == 1, "pressing E triggers only the card's primary prompt, once", "triggered: " .. (if #fired > 0 then table.concat(fired, ", ") else "nothing"))
	done()

	-- the target goes away: the next prompt takes the card
	collect.Enabled = false
	H.run(0.6)
	local lbl = primaryLabel()
	Report.check(lbl ~= nil and lbl ~= "Collect drive", "a disabled target hands the card to the next prompt", "primary now: " .. tostring(lbl))

	-- hold timing through the key
	counts, done = triggers()
	local holdTarget = nil
	for _, p in all do
		if p.ActionText == lbl then
			holdTarget = p
		end
	end
	if holdTarget and holdTarget.HoldDuration > 0 then
		local key = holdTarget.KeyboardKeyCode
		World.keyDown(key)
		H.run(holdTarget.HoldDuration * 0.5)
		Report.check(counts[holdTarget] == 0, "hold prompt does not trigger before HoldDuration", holdTarget.ActionText)
		H.run(holdTarget.HoldDuration * 0.7)
		World.keyUp(key)
		H.step(3)
		Report.check(counts[holdTarget] == 1, "hold prompt triggers once after HoldDuration", string.format("%s x%d", holdTarget.ActionText, counts[holdTarget]))
	else
		Report.warn("no hold prompt became primary; hold timing not checked", tostring(lbl))
	end
	done()
	collect.Enabled = true
	H.run(0.6)

	-- input types relabel the keycap
	local keycaps = {}
	for _, kind in { "gamepad", "touch", "keyboard" } do
		World.setInputType(kind)
		H.run(0.4)
		local tps = cards()
		local texts = {}
		if tps[1] then
			Rt.eachDescendant(tps[1], function(d)
				if H.isText(d) and H.isShown(d) then
					local t = Layout.labelText(d)
					if #t > 0 and #t <= 4 then
						table.insert(texts, t)
					end
				end
			end)
		end
		keycaps[kind] = table.concat(texts, "/")
		Report.check(#tps <= 1, "at most one card with " .. kind .. " input", #tps .. " cards")
	end
	Report.info(string.format("keycap text by input: keyboard=%s gamepad=%s touch=%s", keycaps.keyboard, keycaps.gamepad, keycaps.touch))
	Report.check(keycaps.gamepad ~= keycaps.keyboard, "gamepad input changes the keycap label")

	-- touch: tapping the card triggers the primary prompt
	World.setInputType("touch")
	H.run(0.4)
	counts, done = triggers()
	local plabel, card = primaryLabel()
	local target = nil
	if card then
		-- the touch target: a GuiButton in the card that holds the primary label
		Rt.eachDescendant(card, function(d)
			if target == nil and H.Api.isA(d.class, "GuiButton") and H.isShown(d) then
				local has = false
				Rt.eachDescendant(d, function(x)
					if H.isText(x) and Layout.labelText(x) == plabel then
						has = true
					end
				end)
				if has then
					target = d
				end
			end
		end)
		if target == nil and H.Api.isA(card.class, "GuiButton") then
			target = card
		end
	end
	local primaryPrompt = nil
	for _, p in all do
		if p.ActionText == plabel then
			primaryPrompt = p
		end
	end
	if target and primaryPrompt then
		H.tap(target)
		H.run(primaryPrompt.HoldDuration + 0.2)
		local total = 0
		for _, p in all do
			total += counts[p]
		end
		Report.check(primaryPrompt.HoldDuration > 0 or (counts[primaryPrompt] == 1 and total == 1), "tapping the card triggers its primary prompt once (touch)", string.format("%s x%d, %d triggers in total", primaryPrompt.ActionText, counts[primaryPrompt], total))
	else
		Report.check(false, "tapping the card triggers its primary prompt once (touch)", "no tappable element holding the primary label")
	end
	done()
	World.setInputType("keyboard")
	H.run(0.4)

	-- desktop open hides the card, closing restores it
	World.seat(World.humanoid, H.seatPart)
	Server.startSession()
	H.run(0.5)
	local open = #cards()
	Server.endSession("smoke")
	World.unseat(World.humanoid)
	H.step(1)
	aim()
	H.run(0.6)
	local after = #cards()
	Report.check(open == 0, "prompt card hidden while the desktop is open", open .. " cards")
	Report.check(after == 1, "prompt card returns after leaving the desktop", after .. " cards")

	-- phone viewport (let the card's smoothing settle)
	World.setViewport(667, 375)
	H.run(1)
	local tps = cards()
	if tps[1] then
		Report.check(inViewport(tps[1]), "prompt card inside a 667x375 viewport", rectOf(tps[1]))
	end
	World.setViewport(1366, 768)
	H.run(1)

	-- turn around: every prompt leaves the screen
	local function face(yaw: number)
		local rp = root.Position
		root.CFrame = CF.new(rp.X, rp.Y, rp.Z) * CF.Angles(0, yaw, 0)
		local head = World.character:FindFirstChild("Head")
		head.CFrame = root.CFrame * CF.new(0, 1.5, 0)
		aim()
	end
	face(math.pi)
	H.run(0.8)
	tps = cards()
	Report.check(#tps == 0 or inViewport(tps[1]), "turning away from every prompt hides the card (or keeps it on screen)", #tps .. " cards")
	face(0)
	H.run(0.8)
	Report.check(#cards() == 1, "facing the prompts again brings the card back")

	-- the targeted prompt's part is destroyed (a teammate took the drive)
	collect.Parent:Destroy()
	H.run(0.8)
	lbl = primaryLabel()
	Report.check(lbl ~= "Collect drive", "destroying the targeted prompt drops it from the card", "primary now: " .. tostring(lbl))
	holder:Destroy()
	H.run(0.8)
	Report.check(#cards() == 0, "no card once every prompt is gone", #cards() .. " cards")
end
