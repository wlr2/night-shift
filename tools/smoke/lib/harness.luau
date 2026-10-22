--!nocheck
-- Shared scenario context: world setup and query helpers.

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local Api = require("./api")
local Rt = require("./rt")
local Sched = require("./sched")
local World = require("./services")
local Layout = require("./layout")
local Loader = require("./loader")
local Server = require("./server")
local Report = require("./report")

local V3, CF = roblox.Vector3, roblox.CFrame
local E = Rt.Enum
local recs = Rt.recs

local H = {}
H.World = World
H.Api = Api
H.Rt = Rt
H.Sched = Sched
H.Layout = Layout
H.Loader = Loader
H.Server = Server
H.Report = Report
H.E = E

function H.setup(repoRoot: string, apiPath: string?)
	Api.load(apiPath or (repoRoot .. "/tools/smoke/api_members.json"))
	Sched.onError = function(msg, tb, kind)
		Report.error(msg, tb, kind)
	end
	Rt.onWarn = function(text, site)
		Report.gameWarn(text, site)
	end
	Rt.onPrint = function(text, site)
		Report.gamePrint(text, site)
	end
	H.harnessNotes = {}
	Rt.onNote = function(msg)
		table.insert(H.harnessNotes, msg)
	end
	math.randomseed(7)
	World.build()
	Loader.root = repoRoot
	Loader.makeGlobals()
	Loader.mount("default.project.json")
	H.makeRemotes(repoRoot)
	H.shared = World.services.ReplicatedStorage:FindFirstChild("Shared")
	H.Config = Loader.require(H.shared.Config)
	H.Dialogue = Loader.require(H.shared.Dialogue)
	H.LayoutData = Loader.require(H.shared.Layout)
	local serverRoot = World.services.ServerScriptService:FindFirstChild("Server")
	H.serverRoot = serverRoot
	Server.init(Loader.require(serverRoot.Minigames), H.Config, H.Dialogue)
	local sources = {}
	Rt.eachDescendant(Rt.rec(serverRoot), function(d)
		if d.sourceText then
			sources[d.name] = d.sourceText
		end
	end)
	Server.syncRules(sources)
	Server.install()
	H.makeMap()
	World.addTeammate("Ana", 2002, { Carrying = "HD-2203" })
	World.addTeammate("Ben", 2003, { Downed = true })
	H.clientRoot = World.player:FindFirstChild("PlayerScripts"):FindFirstChild("Client")
end

-- Remotes folder exactly as Net.luau's server path creates it.
function H.makeRemotes(repoRoot: string)
	local src = fs.readFile(repoRoot .. "/src/shared/Net.luau")
	local list = string.match(src, "local%s+NAMES[^=]*=%s*(%b{})")
	local names = {}
	if list then
		for n in string.gmatch(list, '"([%w_]+)"') do
			table.insert(names, n)
		end
	end
	if #names == 0 then
		names = { "State", "Session", "Notify", "Fx", "Desktop", "Leave", "Ping", "Cheat" }
		Report.info("could not parse Net.luau NAMES; using the built-in remote list")
	end
	H.remoteNames = names
	local f = Rt.newInstance("Folder", { name = "Remotes" })
	for _, n in names do
		local r = Rt.newInstance("RemoteEvent", { name = n })
		r.Parent = f
	end
	f.Parent = World.services.ReplicatedStorage
end

-- A tiny stand-in for the server-built map: only the parts the client
-- controllers look up by name (Map.Interactive.*), a seat and some tagged
-- art anchors / surfaces so ArtController and Atmosphere run their paths.
function H.makeMap()
	local L = H.LayoutData
	local ws = World.workspace
	local map = Rt.newInstance("Model", { name = "Map" })
	local inter = Rt.newInstance("Folder", { name = "Interactive" })
	inter.Parent = map
	local function part(name: string, pos: any, parent: any, class: string?): any
		local p = Rt.newInstance(class or "Part", { name = name })
		p.Anchored = true
		p.Size = V3.new(1, 1, 1)
		p.CFrame = CF.new(pos.X, pos.Y, pos.Z)
		p.Parent = parent
		return p
	end
	for i, d in L.DESKS do
		local s = part("SourceScreen_" .. i, d.pos + V3.new(0, 4, 0), inter)
		s:SetAttribute("Text", if i == 2 then "WHO IS STILL HERE" else "")
		part("SourcePC_" .. i, d.pos + V3.new(1, 3.5, 0), inter)
	end
	local light = part("DoorStatusLight", L.DOOR_LIGHT, inter)
	light:SetAttribute("Alert", true)
	part("PrinterLed", L.PRINTER, inter)
	part("DriveDock", L.WORKSTATION.dock, inter)
	part("SeatPrompt", L.WORKSTATION.chair + V3.new(0, 2, 0), inter)
	local seat = part("WorkstationSeat", L.WORKSTATION.chair + V3.new(0, 1, 0), map, "Seat")
	H.seatPart = seat
	local glass = part("Window1", V3.new(-14, 5, -14), map)
	glass:SetAttribute("RainGlass", true)
	local floor = part("Floor", V3.new(0, -0.5, 0), map)
	floor.Size = V3.new(44, 1, 28)
	local tex = Rt.newInstance("Texture", { name = "Carpet" })
	tex:SetAttribute("Surface", "carpet")
	tex.Parent = floor
	tex:AddTag("Surface")
	local anchors = Rt.newInstance("Folder", { name = "ArtAnchors" })
	anchors.Parent = map
	local keys = { "office__desks__desk2", "office__extras__mug", "office__computers__computer_monitor" }
	for i, k in keys do
		local a = part("Anchor_" .. k, V3.new(-14 + i * 3, 0, -2.6), anchors)
		a.Transparency = 1
		a:SetAttribute("ArtKey", k)
		a:AddTag("ArtAnchor")
	end
	local dyn = part("FigureAnchor", V3.new(80, -50, 6), anchors)
	dyn:SetAttribute("ArtKey", "characters__male__character_01")
	dyn:SetAttribute("ArtDynamic", true)
	dyn:AddTag("ArtAnchor")
	map.Parent = ws
	H.map = map
	H.interactive = inter
end

-------------------------------------------------------------------------------
-- frame stepping

function H.step(n: number?, dt: number?)
	for _ = 1, n or 1 do
		World.step(dt)
	end
end

function H.run(seconds: number, dt: number?)
	World.run(seconds, dt)
end

function H.clientModule(rel: string): any
	-- rel like "Controllers/Desktop" or "Ui/Cursor"
	local inst = H.clientRoot
	for part in string.gmatch(rel, "[^/]+") do
		inst = inst and inst:FindFirstChild(part)
	end
	if not inst then
		return nil
	end
	local c = Loader.loaded[inst]
	return c and c.value
end

-------------------------------------------------------------------------------
-- GUI queries (use the layout from the last frame)

local function area(L: any): number
	if not L or not L.w or not L.clip then
		return 0
	end
	local x0, y0 = math.max(L.x, L.clip[1], 0), math.max(L.y, L.clip[2], 0)
	local x1 = math.min(L.x + L.w, L.clip[3], Layout.viewport.w)
	local y1 = math.min(L.y + L.h, L.clip[4], Layout.viewport.h)
	return math.max(0, x1 - x0) * math.max(0, y1 - y0)
end
H.area = area

function H.isShown(r: any): boolean
	local L = r.layout
	return L ~= nil and L.visible == true and area(L) > 0.5
end

function H.screenGuis(): { any }
	local out = {}
	for _, c in recs[World.playerGui].children do
		local r = recs[c]
		if r.class == "ScreenGui" then
			table.insert(out, r)
		end
	end
	return out
end

local function isText(r: any): boolean
	return r.class == "TextLabel" or r.class == "TextButton" or r.class == "TextBox"
end
H.isText = isText

-- visible, non-empty text objects
function H.texts(root: any?): { any }
	local out = {}
	local roots = if root then { root } else H.screenGuis()
	for _, sg in roots do
		Rt.eachDescendant(sg, function(d)
			if isText(d) and H.isShown(d) then
				local text = Layout.labelText(d)
				if string.match(text, "%S") and (d.proxy.TextTransparency or 0) < 0.99 then
					table.insert(out, d)
				end
			end
		end)
	end
	return out
end

function H.findText(substr: string, plain: boolean?): any
	local needle = string.lower(substr)
	for _, r in H.texts() do
		if string.find(string.lower(Layout.labelText(r)), needle, 1, true) then
			return r
		end
	end
	return nil
end

function H.allText(): string
	local parts = {}
	for _, r in H.texts() do
		table.insert(parts, Layout.labelText(r))
	end
	return table.concat(parts, " | ")
end

function H.buttons(root: any?): { any }
	local out = {}
	local roots = if root then { root } else H.screenGuis()
	for _, sg in roots do
		Rt.eachDescendant(sg, function(d)
			if Api.isA(d.class, "GuiButton") and H.isShown(d) then
				table.insert(out, d)
			end
		end)
	end
	return out
end

function H.label(r: any): string
	local t = if isText(r) then Layout.labelText(r) else ""
	if t == "" then
		-- first visible descendant text
		Rt.eachDescendant(r, function(d)
			if t == "" and isText(d) then
				t = Layout.labelText(d)
			end
		end)
	end
	t = string.gsub(t, "%s+", " ")
	return string.format("%s [%s]", r.name, string.sub(t, 1, 40))
end

function H.isLeaveButton(r: any): boolean
	local s = string.lower(r.name .. " " .. H.label(r))
	return string.find(s, "leave", 1, true) ~= nil or string.find(s, "stand up", 1, true) ~= nil
end

-- A press on a GUI object: one InputObject for the whole press (Roblox
-- reuses it from Began to Ended), GuiObject input events, UserInputService
-- InputBegan/InputEnded with gameProcessedEvent = true, then the button
-- click events and Activated.
function H.click(r: any, inputType: any?)
	local itype = inputType or E.UserInputType.MouseButton1
	local uis = World.services.UserInputService
	local io = World.inputObject(nil, itype, E.UserInputState.Begin)
	local p = r.proxy
	Rt.fire(Rt.getSignal(p, "InputBegan"), io)
	Rt.fire(Rt.getSignal(uis, "InputBegan"), io, true)
	if r.impl.members.MouseButton1Down then
		Rt.fire(Rt.getSignal(p, "MouseButton1Down"), World.mouse.X, World.mouse.Y)
	end
	Sched.flushDeferred()
	Rt.setInternal(io, "UserInputState", E.UserInputState.End)
	Rt.fire(Rt.getSignal(p, "InputEnded"), io)
	Rt.fire(Rt.getSignal(uis, "InputEnded"), io, true)
	if r.impl.members.MouseButton1Up then
		Rt.fire(Rt.getSignal(p, "MouseButton1Up"), World.mouse.X, World.mouse.Y)
		Rt.fire(Rt.getSignal(p, "MouseButton1Click"))
	end
	if r.impl.members.Activated then
		Rt.fire(Rt.getSignal(p, "Activated"), io, 1)
	end
	Sched.flushDeferred()
end

function H.tap(r: any)
	H.click(r, E.UserInputType.Touch)
end

function H.camState(): any
	local uis = World.services.UserInputService
	local Cursor = H.clientModule("Ui/Cursor")
	local Desktop = H.clientModule("Controllers/Desktop")
	local free = nil
	if Cursor and type(Cursor.isFree) == "function" then
		local ok, v = pcall(Cursor.isFree)
		free = if ok then v else nil
	end
	local open = nil
	if Desktop and type(Desktop.isOpen) == "function" then
		local ok, v = pcall(Desktop.isOpen)
		open = if ok then v else nil
	end
	-- a visible GuiButton with Modal = true makes the engine release the
	-- mouse lock whatever MouseBehavior says (Roblox behaviour)
	local modal = H.modalVisible() or World.services.GuiService.MenuIsOpen == true
	local prop = tostring(uis.MouseBehavior)
	return {
		cameraType = tostring(World.camera.CameraType),
		cameraMode = tostring(World.player.CameraMode),
		mouse = if modal then tostring(E.MouseBehavior.Default) else prop,
		mouseProp = prop,
		modal = modal,
		icon = uis.MouseIconEnabled,
		cursorFree = free,
		desktopOpen = open,
	}
end

function H.modalVisible(): boolean
	local found = false
	for _, sg in H.screenGuis() do
		if not found and sg.proxy.Enabled then
			Rt.eachDescendant(sg, function(d)
				if not found and Api.isA(d.class, "GuiButton") and d.proxy.Modal == true then
					local cur, vis = d, true
					while cur and cur ~= sg do
						if cur.impl.members.Visible and cur.proxy.Visible == false then
							vis = false
							break
						end
						cur = cur.parent and recs[cur.parent]
					end
					found = vis
				end
			end)
		end
	end
	return found
end

function H.fmtCam(s: any): string
	local function short(x)
		return string.match(tostring(x), "([%w_]+)$") or tostring(x)
	end
	local mouse = short(s.mouse)
	if s.modal and s.mouseProp ~= s.mouse then
		mouse = string.format("%s (released by a visible Modal button or the Roblox menu; property %s)", mouse, short(s.mouseProp))
	end
	return string.format("CameraType=%s CameraMode=%s MouseBehavior=%s MouseIconEnabled=%s Cursor.isFree=%s Desktop.isOpen=%s", short(s.cameraType), short(s.cameraMode), mouse, tostring(s.icon), tostring(s.cursorFree), tostring(s.desktopOpen))
end

function H.remoteCalls(since: number, name: string?): { any }
	local out = {}
	for i = since + 1, #World.remoteLog do
		local c = World.remoteLog[i]
		if not name or c.remote == name then
			table.insert(out, c)
		end
	end
	return out
end

-- Fires a server->client remote with the same deep copy the network does.
function H.fire(name: string, ...: any)
	Server.fireClient(name, ...)
	Sched.flushDeferred()
end

return H
