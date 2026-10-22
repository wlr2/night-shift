--!nocheck
-- f. Legibility sweep at 667x375, 1366x768, 1920x1080 and 2560x1440 in the
-- HUD state (walking, toasts, threats, prompt card) and the desktop state
-- (minigame + Messenger + fragment windows). Effective text size =
-- TextSize (or the fitted TextScaled size within UITextSizeConstraint) x the
-- accumulated UIScale. Readable fonts below 13 px and pixel fonts below 8 px
-- are flagged, as are visible elements that extend beyond the viewport.
-- Sizes come from the harness's approximate layout (tools/smoke/README.md).

local roblox = require("@lune/roblox")
local V3, CF = roblox.Vector3, roblox.CFrame

local VIEWPORTS = { { 667, 375 }, { 1366, 768 }, { 1920, 1080 }, { 2560, 1440 } }
local MIN_READABLE = 13
local MIN_PIXEL = 8

return function(H)
	local Report, World, Server, Rt, E, Layout = H.Report, H.World, H.Server, H.Rt, H.E, H.Layout
	Report.begin("f", "legibility sweep")

	-- a prompt in front of the camera for the HUD state
	World.respawn()
	H.step(3)
	local eye = World.character:FindFirstChild("HumanoidRootPart").Position + V3.new(0, 1.5, 0)
	local part = Rt.newInstance("Part", { name = "LegibilityPrompt" })
	part.Anchored = true
	local pp = eye + V3.new(0.5, -1, -4)
	part.CFrame = CF.new(pp.X, pp.Y, pp.Z)
	part.Parent = World.workspace
	local prompt = Rt.createInstance("ProximityPrompt")
	prompt.ActionText = "Collect drive"
	prompt.ObjectText = "HD-3318"
	prompt.Style = E.ProximityPromptStyle.Custom
	prompt.Parent = part

	local function hudState()
		if World.humanoid.Sit then
			World.unseat(World.humanoid)
		end
		Server.endSession("legibility")
		World.player:SetAttribute("Carrying", "HD-3318")
		Server.pushState()
		H.fire("Notify", "Checkpoint saved. Two drives erased; four to go.", "good")
		H.fire("Fx", "BossMessage", { id = 90, from = "R. Kessler", text = "Why is the rear door open? Latch it.", kind = "request" })
		-- the prompt engine stand-in shows the prompt (in reach, on screen)
		H.step(8)
	end
	local function desktopState()
		World.player:SetAttribute("Carrying", nil)
		World.seat(World.humanoid, H.seatPart)
		Server.startSession()
		Server.dockDrive(1, "FileSort")
		Server.job = Server.Minigames.newJob("FileSort", false, 77)
		Server.pushSession()
		H.step(4)
		-- open the Messenger and Procedures windows through their icons
		for _, b in H.buttons() do
			local l = string.lower(H.label(b))
			if string.find(l, "messenger", 1, true) and not string.find(string.lower(b.name), "task", 1, true) then
				H.click(b)
				H.step(2)
				break
			end
		end
		H.fire("Fx", "Fragment", { index = 2 })
		H.step(8)
	end

	local function collect(): ({ any }, { any }, any)
		local small, off = {}, {}
		local seen = {}
		local minimum = { readable = nil, pixel = nil }
		for _, r in H.texts() do
			local L = r.layout
			local _, pixel = Layout.fontInfo(r)
			local fam = Layout.fontInfo(r)
			local size = Layout.textSize(r, L.lw, L.lh) * (L.k or 1)
			local limit = if pixel then MIN_PIXEL else MIN_READABLE
			local kind = if pixel then "pixel" else "readable"
			if minimum[kind] == nil or size < minimum[kind].size then
				minimum[kind] = { size = size, r = r, fam = fam }
			end
			if size < limit - 0.05 then
				table.insert(small, { r = r, size = size, fam = fam, pixel = pixel })
			end
		end
		local vw, vh = Layout.viewport.w, Layout.viewport.h
		for _, sg in H.screenGuis() do
			local function walk(r: any)
				for _, c in r.children do
					local cr = Rt.rec(c)
					local L = cr.layout
					if L and L.visible and L.w and L.clip then
						local visual = H.isText(cr) or (cr.impl.members.BackgroundTransparency and (cr.proxy.BackgroundTransparency or 1) < 0.95) or cr.class == "ImageLabel" or cr.class == "ImageButton"
						local x0, y0 = math.max(L.x, L.clip[1]), math.max(L.y, L.clip[2])
						local x1, y1 = math.min(L.x + L.w, L.clip[3]), math.min(L.y + L.h, L.clip[4])
						if visual and x1 > x0 and y1 > y0 and (x0 < -2 or y0 < -2 or x1 > vw + 2 or y1 > vh + 2) then
							if not seen[cr] then
								table.insert(off, { r = cr, rect = { x0, y0, x1, y1 } })
							end
							-- children of an offending element are not listed again
							Rt.eachDescendant(cr, function(d)
								seen[d] = true
							end)
						else
							walk(cr)
						end
					end
				end
			end
			if sg.layout and sg.layout.visible then
				walk(sg)
			end
		end
		return small, off, minimum
	end

	local function short(r: any): string
		local name = Rt.fullName(r)
		name = string.gsub(name, "^Players%.[^%.]+%.PlayerGui%.", "")
		return name
	end

	local totals = {}
	for _, state in { "hud", "desktop" } do
		for _, vp in VIEWPORTS do
			World.setViewport(vp[1], vp[2])
			H.step(4)
			if state == "hud" then
				hudState()
			else
				desktopState()
			end
			H.step(4)
			local small, off, minimum = collect()
			local key = string.format("%s @ %dx%d", state, vp[1], vp[2])
			local function m(x)
				return if x then string.format("%.1f px %s (%s)", x.size, x.fam, string.sub(string.gsub(Layout.labelText(x.r), "%s+", " "), 1, 24)) else "-"
			end
			Report.info(string.format("%-20s smallest readable %s; smallest pixel-font %s", key, m(minimum.readable), m(minimum.pixel)))
			local phone = vp[2] < 500
			table.sort(small, function(a, b)
				return a.size < b.size
			end)
			local detail = {}
			local seenText = {}
			for _, s in small do
				local t = string.gsub(Layout.labelText(s.r), "%s+", " ")
				local k = short(s.r) .. "|" .. t
				if not seenText[k] and #detail < 14 then
					seenText[k] = true
					table.insert(detail, string.format("%5.1f px  %-12s %s  \"%s\"", s.size, s.fam, short(s.r), string.sub(t, 1, 48)))
				end
			end
			if #small > #detail then
				table.insert(detail, string.format("... %d more", #small - #detail))
			end
			local label = string.format("%s: no readable text < %d px, no pixel-font text < %d px", key, MIN_READABLE, MIN_PIXEL)
			if #small == 0 then
				Report.check(true, label)
			elseif phone then
				Report.warn(label .. string.format(" (%d below)", #small), table.concat(detail, "\n"))
			else
				Report.check(false, label .. string.format(" (%d below)", #small), table.concat(detail, "\n"))
			end
			local od = {}
			for i, o in off do
				if i > 10 then
					table.insert(od, string.format("... %d more", #off - 10))
					break
				end
				table.insert(od, string.format("%s  [%.0f,%.0f - %.0f,%.0f]", short(o.r), o.rect[1], o.rect[2], o.rect[3], o.rect[4]))
			end
			if #off == 0 then
				Report.check(true, key .. ": nothing visible extends beyond the viewport")
			else
				Report.warn(key .. string.format(": %d visible element(s) extend beyond the viewport (approximate layout)", #off), table.concat(od, "\n"))
			end
			totals[key] = #H.texts()
		end
	end
	local t = {}
	for k, v in totals do
		table.insert(t, k .. "=" .. v)
	end
	table.sort(t)
	Report.info("visible text objects per state: " .. table.concat(t, ", "))

	-- restore
	World.setViewport(1366, 768)
	Server.endSession("legibility done")
	if World.humanoid.Sit then
		World.unseat(World.humanoid)
	end
	part:Destroy()
	H.step(3)
end
