--!strict
-- The workstation desktop: a native-GUI, late-90s office OS shell that
-- hosts every SecureErase utility. Opens when the server starts a session
-- for this player and closes the moment the session ends. Everything here is
-- presentation: actions are sent to the server as semantic commands tagged
-- with the session id, and the server answers with the authoritative state.
--
-- Look (docs/ART_DIRECTION.md): slate-teal desktop, cream bevelled windows
-- with charcoal-blue title bars, square corners. Silkscreen only for titles,
-- status and the tray clock; Ubuntu for sentences and buttons; Inconsolata
-- for listings; Merriweather for recovered fragments.
--
-- Scaling: the desktop is laid out in logical pixels on a canvas scaled to
-- the monitor. Big screens see a BASE_W x BASE_H desktop (scale capped at
-- MAX_SCALE). Small screens get a smaller logical desktop, down to
-- MIN_W x MIN_H (main window + taskbar), instead of a smaller scale, so
-- 16 px text still lands at ~13 px on a 667x375 phone.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local Dialogue = require(ReplicatedStorage.Shared.Dialogue)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)
local State = require(script.Parent.State)
local Cursor = require(script.Parent.Parent.Ui.Cursor)
local UiKit = require(script.Parent.Parent.Ui.UiKit)

local C = UiKit.C
local SPACE = UiKit.SPACE
local player = Players.LocalPlayer

local Views: { [string]: any } = {}
for _, m in script.Parent.Parent:WaitForChild("Views"):GetChildren() do
	if m:IsA("ModuleScript") then
		Views[m.Name] = (require :: any)(m)
	end
end

local Desktop = {}

-- logical layout (px before the canvas UIScale)
local BASE_W, BASE_H = 960, 600
local MIN_W, MIN_H = 776, 452
local MAX_SCALE = 1.6
local COMPACT_BELOW = 0.92 -- bezel-less monitor when the framed screen would scale below this
local TB = 32 -- taskbar height
local ICON_W, ICON_H = 100, 66
local MAIN_X, MAIN_W, MAIN_H = 108, 660, 416
local STAGE_W = 194
local GAME_W, GAME_H = 620, 250 -- the minigame Views draw into exactly this
local SIDE_W = 460
local FRAG_W, FRAG_H = 480, 268
local PHANTOM_W, PHANTOM_H = 360, 196
local TASK_W = 128
local TRAY_W = 480
local LEAVE_TASKBAR_W = 136

-- desktop-only tones, derived from the shared palette
local D = {
	wallTop = C.desktop:Lerp(C.slate, 0.25),
	wallBottom = C.desktop:Lerp(C.charcoal, 0.55),
	wallMark = C.desktop:Lerp(C.fog, 0.22),
	plastic = C.cream, -- monitor bezel: old plastic
	plasticDark = C.cream:Lerp(C.charcoal, 0.5),
	paper = Color3.fromRGB(246, 242, 230), -- recovered fragments
	well = C.face:Lerp(C.faceDark, 0.1), -- sunken tray
	tip = Color3.fromRGB(238, 228, 204), -- hint strip and tooltip
	tipLine = Color3.fromRGB(150, 118, 64),
	locked = C.face:Lerp(C.faceDark, 0.15),
	phantom1 = Color3.fromRGB(112, 38, 32), -- phantom title bar: red-brown, never blue (learned cue)
	phantom2 = Color3.fromRGB(160, 92, 64),
	phantomText = Color3.fromRGB(255, 226, 214),
	led = Color3.fromRGB(120, 196, 120),
	folderTab = C.amber:Lerp(C.charcoal, 0.25),
	folderLip = C.amber:Lerp(C.white, 0.35),
}

local W, H = BASE_W, BASE_H
local compact = false

local gui: ScreenGui
local bezel: Frame
local screen: Frame
local canvas: Frame
local canvasScale: UIScale
local chin: Frame
local chinScale: UIScale
local chinLed: Frame
local wallMark: Frame
local windowsLayer: Frame
local powerOn: Frame
local mainWin: UiKit.Window
local mainParts: {
	header: TextLabel,
	stage: TextLabel,
	progressFill: Frame,
	instructions: TextLabel,
	game: Frame,
	feedback: TextLabel,
	hintBox: Frame,
	hint: TextLabel,
	overlay: Frame,
	overlayText: TextLabel,
}
local side: { [string]: UiKit.Window } = {}
local sideOpen: { [string]: boolean } = {}
local taskbar: Frame
local taskbarTray: { erased: TextLabel, door: TextLabel, power: TextLabel, clock: TextLabel }
local taskButtons: { TextButton } = {}
local unreadMarks: { Frame } = {}
local startBtn: TextButton
local startMenu: Frame
local firstMenuItem: TextButton? = nil
local toast: TextButton
local toastFrom: TextLabel
local toastText: TextLabel
local phantomFrame: Frame?
local fragmentWin: UiKit.Window?
local leaveButton: TextButton

local isOpen = false
local session: Types.SessionPayload? = nil
local lastViewKey = ""
local zTop = 20
local filesSelection: number? = nil
local sideKeys: { [string]: string } = {}
local finaleKey = ""

-- cheap content signature per side app, so snapshots that change nothing
-- relevant do not rebuild the window (scroll position and focus survive)
local function sideKey(name: string, snap: Types.Snapshot): string
	if name == "Messenger" then
		local last = snap.boss[#snap.boss]
		local open = 0
		for _, m in snap.boss do
			if m.answered then
				open += 1
			end
		end
		return string.format("%d:%s:%d", #snap.boss, if last then tostring(last.id) else "-", open)
	elseif name == "DriveInfo" then
		local parts = {}
		for _, d in snap.drives do
			table.insert(parts, d.state .. math.floor(d.progress * 20) .. (d.carrier or ""))
		end
		return table.concat(parts, "|")
	end
	return "static"
end

local function finaleSignature(snap: Types.Snapshot): string
	local parts: { string } = { snap.phase :: string, tostring(snap.power.workstation) }
	if snap.purge then
		for _, e in snap.purge do
			table.insert(parts, e.name .. tostring(e.cancelled))
		end
		table.insert(parts, tostring(math.floor(snap.purgeDeadline or 0)))
	end
	if snap.signOff then
		table.insert(parts, tostring(math.floor(snap.signOff.progress * 100)) .. tostring(snap.signOff.awaiting))
	end
	return table.concat(parts, ";")
end

local function send(kind: string, a: any?, b: any?, c: any?)
	local s = session
	if not s then
		return
	end
	Net.remote("Desktop"):FireServer(s.sessionId, kind, a, b, c)
end

function Desktop.leave()
	Net.remote("Leave"):FireServer()
	local character = player.Character
	local h = character and character:FindFirstChildOfClass("Humanoid")
	if h then
		h.Sit = false
		h.Jump = true
	end
end

-- Small pixel glyphs ----------------------------------------------------------
-- Each piece is { x, y, w, h, colour, outlined? } on a 16-unit grid; k scales
-- it (k = 2 for 32 px desktop icons, k = 1 for 16 px menu and taskbar icons).

local GLYPHS: { [string]: { { any } } } = {
	erase = { { 1, 2, 14, 12, C.face, true }, { 2, 3, 12, 3, C.title1 }, { 3, 8, 10, 3, C.field, true }, { 3, 8, 6, 3, C.good } },
	messenger = { { 1, 2, 10, 7, C.slate, true }, { 5, 6, 10, 8, C.white, true }, { 7, 8, 6, 1, C.faceDark }, { 7, 10, 4, 1, C.faceDark } },
	folder = { { 1, 3, 6, 2, D.folderTab, true }, { 1, 4, 14, 10, C.amber, true }, { 2, 6, 12, 1, D.folderLip } },
	drive = { { 1, 4, 14, 9, C.charcoal, true }, { 3, 6, 7, 3, C.cream }, { 11, 10, 2, 1, D.led } },
	text = { { 3, 1, 10, 14, C.white, true }, { 5, 4, 6, 1, C.faceDark }, { 5, 6, 6, 1, C.faceDark }, { 5, 8, 6, 1, C.faceDark }, { 5, 10, 4, 1, C.faceDark } },
	door = { { 4, 1, 8, 14, C.burgundy, true }, { 9, 8, 1, 1, C.amber } },
	logo = { { 1, 1, 14, 14, C.charcoal, true }, { 5, 5, 6, 6, C.amber } },
}

local function glyph(parent: Instance, kind: string, x: number, y: number, k: number, z: number): Frame
	local box = UiKit.frame({ Name = "Glyph", Size = UDim2.fromOffset(16 * k, 16 * k), Position = UDim2.fromOffset(x, y), BackgroundTransparency = 1, ZIndex = z, Parent = parent })
	local pieces = GLYPHS[kind]
	if not pieces then
		return box
	end
	for _, r in pieces do
		UiKit.frame({
			Size = UDim2.fromOffset(r[3] * k, r[4] * k),
			Position = UDim2.fromOffset(r[1] * k, r[2] * k),
			BackgroundColor3 = r[5],
			BorderSizePixel = if r[6] then 1 else 0,
			BorderColor3 = C.edge,
			BorderMode = Enum.BorderMode.Inset,
			ZIndex = z + 1,
			Parent = box,
		})
	end
	return box
end

-- Windows ---------------------------------------------------------------------

local function allWindows(): { UiKit.Window }
	local list: { UiKit.Window } = { mainWin }
	for _, w in side do
		table.insert(list, w)
	end
	if fragmentWin then
		table.insert(list, fragmentWin)
	end
	return list
end

-- the topmost visible window keeps the charcoal-blue title bar
local function refreshActive()
	local top: UiKit.Window? = nil
	for _, w in allWindows() do
		if w.frame.Visible and w.frame.Parent and (not top or w.frame.ZIndex > top.frame.ZIndex) then
			top = w
		end
	end
	for _, w in allWindows() do
		UiKit.setWindowActive(w, w == top)
	end
end

-- ZIndexBehavior is Sibling, so raising the window frame raises the window.
local function bringToFront(w: UiKit.Window)
	zTop += 1
	w.frame.ZIndex = zTop
	if phantomFrame then
		phantomFrame.ZIndex = zTop + 100
	end
	refreshActive()
end

-- clicking a partly covered window raises it, like any desktop
local function trackWindow(w: UiKit.Window)
	w.frame.InputBegan:Connect(function(input: InputObject)
		local t = input.UserInputType
		if (t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch) and w.frame.ZIndex < zTop then
			bringToFront(w)
		end
	end)
end

local function setStartMenu(visible: boolean)
	startMenu.Visible = visible
	-- keep gamepad focus inside the menu while it is open, and out of it after
	local sel = GuiService.SelectedObject
	if visible and sel == startBtn and firstMenuItem then
		GuiService.SelectedObject = firstMenuItem
	elseif not visible and sel and sel:IsDescendantOf(startMenu) then
		GuiService.SelectedObject = startBtn
	end
end

local function setUnread(on: boolean)
	for _, f in unreadMarks do
		f.Visible = on
	end
end

-- Side applications ---------------------------------------------------------

local renderSide: (name: string) -> ()

local function openSide(name: string)
	local w = side[name]
	if not w then
		return
	end
	sideOpen[name] = true
	w.frame.Visible = true
	bringToFront(w)
	renderSide(name)
	setStartMenu(false)
	if name == "Messenger" then
		setUnread(false)
	end
end

local function closeSide(name: string)
	sideOpen[name] = false
	local w = side[name]
	if w then
		w.frame.Visible = false
	end
	refreshActive()
end

-- Sunken white document area with a vertical list (Notepad, Explorer, IM).
local function docArea(body: Frame, z: number, gap: number, bg: Color3?): ScrollingFrame
	local paper = UiKit.frame({ Name = "Paper", Size = UDim2.fromScale(1, 1), BackgroundColor3 = bg or C.field, ZIndex = z, Parent = body })
	UiKit.bevel(paper, true)
	local scroll = UiKit.new("ScrollingFrame", {
		Name = "Doc",
		Size = UDim2.new(1, -4, 1, -4),
		Position = UDim2.fromOffset(2, 2),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 12,
		ScrollBarImageColor3 = C.faceDark,
		ScrollBarImageTransparency = 0,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ZIndex = z + 2,
		Parent = paper,
	}) :: ScrollingFrame
	UiKit.new("UIListLayout", { Padding = UDim.new(0, gap), SortOrder = Enum.SortOrder.LayoutOrder, Parent = scroll })
	UiKit.padding(scroll, SPACE.s)
	return scroll
end

-- One auto-height line of text in a document list.
local function docLine(parent: Instance, role: string, text: string, order: number, props: UiKit.Props?): TextLabel
	local p: UiKit.Props = {
		Text = text,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = order,
		Parent = parent,
	}
	local extra: UiKit.Props = props or {}
	for k, v in extra do
		p[k] = v
	end
	return UiKit.text(role, p)
end

renderSide = function(name: string)
	local w = side[name]
	local snap = State.snapshot
	if not w or not sideOpen[name] or not snap then
		return
	end
	local body = w.body
	UiKit.clear(body)
	local z = body.ZIndex + 1
	if name == "Messenger" then
		local scroll = docArea(body, z, SPACE.m)
		for i, m in snap.boss do
			local tint = if m.kind == "false" then C.bad elseif m.kind == "system" then C.good else C.info
			local block = UiKit.frame({ Name = "Message", Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = i, Parent = scroll })
			UiKit.new("UIListLayout", { Padding = UDim.new(0, SPACE.xs), SortOrder = Enum.SortOrder.LayoutOrder, Parent = block })
			local head = UiKit.frame({ Name = "Head", Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, LayoutOrder = 1, Parent = block })
			UiKit.text("body", { Text = m.from, Font = UiKit.FONT_BOLD, Size = UDim2.new(1, -96, 1, 0), TextColor3 = tint, TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd, Parent = head })
			UiKit.text("mono", {
				Text = State.nightClock(m.t),
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.new(0, 90, 1, 0),
				TextColor3 = C.textDim,
				TextXAlignment = Enum.TextXAlignment.Right,
				TextWrapped = false,
				Parent = head,
			})
			docLine(block, "body", m.text, 2)
			if m.choices and not m.answered then
				local row = UiKit.frame({ Name = "Choices", Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, LayoutOrder = 3, Parent = block })
				for j, choice in m.choices do
					UiKit.button({
						text = choice,
						size = UDim2.fromOffset(176, 28),
						position = UDim2.fromOffset((j - 1) * 184, 1),
						parent = row,
						zindex = 2,
						onClick = function()
							send("bossReply", m.id, j)
						end,
					})
				end
			elseif m.answered then
				docLine(block, "body", "> " .. m.answered, 3, { TextColor3 = C.textDim })
			end
		end
		-- newest message at the bottom, once the list has been measured
		scroll.CanvasPosition = Vector2.new(0, 100000)
		scroll:GetPropertyChangedSignal("AbsoluteCanvasSize"):Connect(function()
			scroll.CanvasPosition = Vector2.new(0, 100000)
		end)
	elseif name == "Procedures" then
		-- a plain text file: one monospaced face, like Notepad
		local scroll = docArea(body, z, SPACE.s)
		docLine(scroll, "mono", "PROCEDURES.TXT - Night Operations (rev. 2006)", 1)
		docLine(scroll, "mono", string.rep("-", 44), 2, { TextColor3 = C.textDim })
		for i, line in Dialogue.PROCEDURES do
			docLine(scroll, "mono", line, 2 + i)
		end
		docLine(scroll, "mono", "If an instruction contradicts these procedures, reject it and cite the number.", 100, { TextColor3 = C.bad })
	elseif name == "Files" then
		local scroll = docArea(body, z, 2)
		local address = UiKit.frame({ Name = "Address", Size = UDim2.new(1, 0, 0, 24), BackgroundColor3 = C.white, BorderSizePixel = 1, BorderColor3 = C.faceDark, BorderMode = Enum.BorderMode.Inset, LayoutOrder = 1, Parent = scroll })
		UiKit.text("mono", { Text = "C:\\RECOVERED\\", Size = UDim2.new(1, -12, 1, 0), Position = UDim2.fromOffset(6, 0), TextWrapped = false, Parent = address })
		docLine(scroll, "body", "Fragments saved before shredding.", 2, { TextColor3 = C.textDim })
		if #snap.fragments == 0 then
			docLine(scroll, "body", "(empty)", 3, { TextColor3 = C.textDim })
		end
		local order = 10
		for _, idx in snap.fragments do
			local f = Dialogue.FRAGMENTS[idx]
			if f then
				order += 1
				local selected = filesSelection == idx
				local fg = if selected then C.white else C.text
				local row = UiKit.button({
					name = "File_" .. idx,
					text = "",
					size = UDim2.new(1, 0, 0, 26),
					parent = scroll,
					color = if selected then C.select else C.field,
					bevel = false,
					onClick = function()
						filesSelection = idx
						renderSide("Files")
					end,
				})
				row.LayoutOrder = order
				UiKit.text("mono", { Text = string.format("%02d", idx), Size = UDim2.new(0, 24, 1, 0), Position = UDim2.fromOffset(6, 0), TextColor3 = fg, TextWrapped = false, Parent = row })
				UiKit.text("mono", { Text = f.title, Size = UDim2.new(1, -190, 1, 0), Position = UDim2.fromOffset(36, 0), TextColor3 = fg, TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
				UiKit.text("body", {
					Text = f.kind,
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.new(1, -6, 0, 0),
					Size = UDim2.new(0, 144, 1, 0),
					TextColor3 = if selected then C.white else C.textDim,
					TextXAlignment = Enum.TextXAlignment.Right,
					TextWrapped = false,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Parent = row,
				})
				if selected then
					order += 1
					local paper = UiKit.frame({ Name = "Fragment", Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = D.paper, LayoutOrder = order, Parent = scroll })
					UiKit.stroke(paper, C.faceDark, 0, 1)
					UiKit.padding(paper, SPACE.m, SPACE.s)
					UiKit.text("letter", { Text = f.body, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, TextYAlignment = Enum.TextYAlignment.Top, Parent = paper })
				end
			end
		end
	elseif name == "DriveInfo" then
		local scroll = docArea(body, z, SPACE.xs)
		docLine(scroll, "heading", string.format("Erased %d of %d", snap.erased, snap.total), 1)
		local cols = UiKit.frame({ Name = "Columns", Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, LayoutOrder = 2, Parent = scroll })
		UiKit.text("title", { Text = "ID", Size = UDim2.new(0, 64, 1, 0), TextColor3 = C.textDim, TextWrapped = false, Parent = cols })
		UiKit.text("title", { Text = "DRIVE", Position = UDim2.fromOffset(68, 0), Size = UDim2.new(0, 136, 1, 0), TextColor3 = C.textDim, TextWrapped = false, Parent = cols })
		UiKit.text("title", { Text = "STATUS", Position = UDim2.fromOffset(210, 0), Size = UDim2.new(0, 100, 1, 0), TextColor3 = C.textDim, TextWrapped = false, Parent = cols })
		UiKit.text("title", { Text = "DONE", AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 60, 1, 0), TextColor3 = C.textDim, TextXAlignment = Enum.TextXAlignment.Right, TextWrapped = false, Parent = cols })
		UiKit.frame({ Name = "Rule", Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = C.faceDark, LayoutOrder = 3, Parent = scroll })
		local order = 10
		for _, d in snap.drives do
			order += 1
			local where = if d.carrier then "Carried by " .. d.carrier else d.state
			local color = if d.state == "Erased" then C.good else C.text
			local row = UiKit.frame({ Name = "Drive_" .. d.id, Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, LayoutOrder = order, Parent = scroll })
			UiKit.text("mono", { Text = d.id, Size = UDim2.new(0, 64, 1, 0), TextColor3 = color, TextWrapped = false, Parent = row })
			UiKit.text("mono", { Text = d.name, Position = UDim2.fromOffset(68, 0), Size = UDim2.new(0, 136, 1, 0), TextColor3 = color, TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
			UiKit.text("body", { Text = where, Position = UDim2.fromOffset(210, 0), Size = UDim2.new(1, -270, 1, 0), TextColor3 = color, TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
			UiKit.text("mono", {
				Text = string.format("%d%%", math.floor(d.progress * 100)),
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.new(0, 56, 1, 0),
				TextColor3 = color,
				TextXAlignment = Enum.TextXAlignment.Right,
				TextWrapped = false,
				Parent = row,
			})
			if d.gameTitle then
				order += 1
				local util = docLine(scroll, "body", "Utility: " .. d.gameTitle, order, { TextColor3 = C.textDim })
				UiKit.new("UIPadding", { PaddingLeft = UDim.new(0, 68), Parent = util })
			end
		end
	end
end

-- Main SecureErase window ----------------------------------------------------

local function setFeedback(text: string?, kind: string?)
	mainParts.feedback.Text = text or ""
	mainParts.feedback.TextColor3 = if kind == "bad" then C.bad elseif kind == "good" then C.good else C.info
end

local function setHint(text: string?)
	local t = text or ""
	mainParts.hint.Text = t
	mainParts.hintBox.Visible = t ~= ""
end

-- centred line inside the minigame area
local function gameLine(g: Frame, role: string, text: string, y: number, z: number, props: UiKit.Props?): TextLabel
	local p: UiKit.Props = {
		Text = text,
		Size = UDim2.new(1, 0, 0, 28),
		Position = UDim2.fromOffset(0, y),
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = z,
		Parent = g,
	}
	local extra: UiKit.Props = props or {}
	for k, v in extra do
		p[k] = v
	end
	return UiKit.text(role, p)
end

local function renderFinale(snap: Types.Snapshot)
	local g = mainParts.game
	UiKit.clear(g)
	local z = g.ZIndex
	mainParts.stage.TextColor3 = C.text
	if snap.phase == "FinalPurge" and snap.purge then
		local left = math.floor(snap.purgeDeadline or 0)
		finaleKey = finaleSignature(snap)
		mainWin.title.Text = "SecureErase :: FINAL PURGE QUEUE"
		mainParts.header.Text = "AUTOMATIC FINAL PURGE: EMPLOYEE RECORDS"
		mainParts.stage.Text = string.format("Executes in %d:%02d", left // 60, left % 60)
		mainParts.stage.TextColor3 = C.bad
		mainParts.instructions.Text = "The final purge includes YOUR employee records. Cancel every entry from tonight, then run EMERGENCY SIGN-OFF."
		-- queue table: up to 8 rows (4 records from 2003 + up to 4 players) above the run button
		UiKit.text("title", { Text = "RECORD", Size = UDim2.fromOffset(200, 20), Position = UDim2.fromOffset(8, 0), TextColor3 = C.textDim, TextWrapped = false, ZIndex = z, Parent = g })
		UiKit.text("title", { Text = "STATUS", Size = UDim2.fromOffset(200, 20), Position = UDim2.fromOffset(372, 0), TextColor3 = C.textDim, TextWrapped = false, ZIndex = z, Parent = g })
		local allDone = true
		for i, e in snap.purge do
			local row = UiKit.frame({
				Name = "Entry",
				Size = UDim2.new(1, 0, 0, 22),
				Position = UDim2.fromOffset(0, 22 + (i - 1) * 24),
				BackgroundColor3 = if e.locked then D.locked else C.field,
				BorderSizePixel = 1,
				BorderColor3 = C.faceDark,
				BorderMode = Enum.BorderMode.Inset,
				ZIndex = z,
				Parent = g,
			})
			UiKit.text("mono", { Text = e.name, Size = UDim2.new(0, 352, 1, 0), Position = UDim2.fromOffset(8, 0), TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = z + 1, Parent = row })
			if e.locked then
				UiKit.text("title", { Text = "PURGED 03-NOV-2003", Size = UDim2.new(0, 240, 1, 0), Position = UDim2.fromOffset(372, 0), TextColor3 = C.bad, TextWrapped = false, ZIndex = z + 1, Parent = row })
			elseif e.cancelled then
				UiKit.text("title", { Text = "REMOVED FROM QUEUE", Size = UDim2.new(0, 240, 1, 0), Position = UDim2.fromOffset(372, 0), TextColor3 = C.good, TextWrapped = false, ZIndex = z + 1, Parent = row })
			else
				allDone = false
				UiKit.button({
					text = "CANCEL",
					size = UDim2.fromOffset(150, 20),
					position = UDim2.fromOffset(372, 1),
					parent = row,
					color = C.bad,
					textColor = C.white,
					zindex = z + 2,
					onClick = function()
						send("purgeCancel", i)
					end,
				})
			end
		end
		local run = UiKit.button({
			text = "RUN EMERGENCY SIGN-OFF",
			size = UDim2.fromOffset(300, 34),
			position = UDim2.new(0.5, -150, 1, -34),
			parent = g,
			color = if allDone then C.good else C.faceDark,
			textColor = C.white,
			textSize = 18,
			zindex = z + 2,
			onClick = function()
				send("signOffStart")
			end,
		})
		UiKit.setEnabled(run, allDone)
		mainParts.progressFill.Size = UDim2.fromScale(1 - math.clamp(left / 150, 0, 1), 1)
		mainParts.progressFill.BackgroundColor3 = C.bad
	elseif snap.phase == "SignOff" and snap.signOff then
		local s = snap.signOff
		mainWin.title.Text = "SecureErase :: EMERGENCY SIGN-OFF"
		mainParts.header.Text = "Writing tonight's timesheets to the off-site backup"
		mainParts.stage.Text = string.format("%d%%", math.floor(s.progress * 100))
		mainParts.instructions.Text = "Keep the workstation powered. At each checkpoint the operator must CONFIRM. Power loss pauses the sign-off; it never resets."
		mainParts.progressFill.Size = UDim2.fromScale(s.progress, 1)
		mainParts.progressFill.BackgroundColor3 = C.good
		local status = if not snap.power.workstation then "PAUSED - NO POWER" elseif s.awaiting then "AWAITING CONFIRMATION" else "RUNNING..."
		gameLine(g, "title", status, 28, z, { TextSize = 24, TextColor3 = if s.awaiting or not snap.power.workstation then C.bad else C.text })
		if s.awaiting then
			UiKit.button({
				text = "CONFIRM CHECKPOINT",
				size = UDim2.fromOffset(300, 56),
				position = UDim2.new(0.5, -150, 0, 92),
				parent = g,
				color = C.good,
				textColor = C.white,
				textSize = 18,
				zindex = z + 1,
				onClick = function()
					send("signOffConfirm")
				end,
			})
		end
	elseif snap.phase == "ClockOut" or snap.phase == "Ending" then
		mainWin.title.Text = "SecureErase"
		mainParts.header.Text = "SIGN-OFF COMPLETE"
		mainParts.stage.Text = ""
		mainParts.instructions.Text = "Your records are safe off-site. Leave the computer, clock out at the lobby time clock and get out."
		mainParts.progressFill.Size = UDim2.fromScale(1, 1)
	end
end

-- empty dock: a row of drive bays showing the team's progress
local function renderNoDrive(g: Frame, snap: Types.Snapshot)
	local z = g.ZIndex
	gameLine(g, "title", "NO DRIVE IN DOCK", 24, z, { TextColor3 = C.textDim })
	local n = math.max(snap.total, 1)
	local bw, gap = 44, 12
	local x0 = (GAME_W - (n * bw + (n - 1) * gap)) // 2
	for i = 1, n do
		local done = i <= snap.erased
		local bay = UiKit.frame({ Name = "Bay", Size = UDim2.fromOffset(bw, 56), Position = UDim2.fromOffset(x0 + (i - 1) * (bw + gap), 66), BackgroundColor3 = if done then C.good else C.field, ZIndex = z, Parent = g })
		UiKit.bevel(bay, not done)
		UiKit.frame({ Name = "Label", Size = UDim2.fromOffset(bw - 16, 8), Position = UDim2.fromOffset(8, 12), BackgroundColor3 = if done then C.good:Lerp(C.white, 0.4) else C.face, ZIndex = z + 2, Parent = bay })
	end
	gameLine(g, "heading", string.format("Team progress: %d of %d drives erased", snap.erased, snap.total), 140, z)
end

local function renderMain()
	local s = session
	local snap = State.snapshot
	if not s or not snap then
		return
	end
	setHint(s.hint)
	setFeedback(s.feedback, s.feedbackKind)
	local noPower = s.reason == "power" or not snap.power.workstation
	mainParts.overlay.Visible = noPower
	if noPower then
		mainParts.overlayText.Text = "The workstation has lost power. Reset the tripped breaker (MAIN / WORKSTATION) at the panel in the UTILITY HALL."
	end
	if snap.phase == "FinalPurge" or snap.phase == "SignOff" or snap.phase == "ClockOut" or snap.phase == "Ending" then
		lastViewKey = "finale"
		renderFinale(snap)
		return
	end
	mainWin.title.Text = s.title or "SecureErase 2.1"
	mainParts.stage.TextColor3 = C.text
	mainParts.progressFill.BackgroundColor3 = C.good
	local g = mainParts.game
	if not s.driveId then
		lastViewKey = "nodrive"
		UiKit.clear(g)
		mainParts.header.Text = "No drive connected"
		mainParts.stage.Text = ""
		mainParts.instructions.Text = "Dock a hard drive at the DOCK on this desk (a teammate can bring one from the rack). Use the desktop apps meanwhile."
		mainParts.progressFill.Size = UDim2.fromScale(0, 1)
		renderNoDrive(g, snap)
		return
	end
	mainParts.header.Text = string.format("Connected: %s  %s", s.driveId, s.driveName or "")
	if not s.view then
		lastViewKey = "start"
		UiKit.clear(g)
		mainParts.stage.Text = "Ready"
		mainParts.instructions.Text = s.instructions or ""
		mainParts.progressFill.Size = UDim2.fromScale(0, 1)
		UiKit.button({
			name = "StartErase",
			text = "START SECURE ERASE",
			size = UDim2.fromOffset(280, 52),
			position = UDim2.new(0.5, -140, 0, 80),
			parent = g,
			color = C.good,
			textColor = C.white,
			textSize = 18,
			zindex = g.ZIndex + 1,
			onClick = function()
				send("start")
			end,
		})
		return
	end
	mainParts.stage.Text = if s.transitioning then "Erasing sectors..." else string.format("Stage %d / %d", s.stage, s.stages)
	mainParts.instructions.Text = s.instructions or ""
	local progress = s.progress or 0
	TweenService:Create(mainParts.progressFill, UiKit.FAST, { Size = UDim2.fromScale(progress, 1) }):Play()
	local view = s.view :: { [string]: any }
	local mod = Views[view.kind]
	if s.transitioning then
		UiKit.clear(g)
		gameLine(g, "title", "PLEASE WAIT", 76, g.ZIndex, { TextColor3 = C.textDim })
		gameLine(g, "heading", "Verifying stage... erasing sectors...", 104, g.ZIndex)
		lastViewKey = "transition"
		return
	end
	if mod then
		lastViewKey = view.kind
		mod.render(g, view, {
			act = function(action: string, a: any, b: any)
				send("act", action, a, b)
			end,
		}, g.ZIndex + 1)
	end
end

-- PHANTOM WINDOW: the learned cue is the red-brown title bar and the real
-- close button on the LEFT; OK is the trap. Keep both cues readable.
local function renderPhantom()
	local s = session
	if phantomFrame then
		phantomFrame:Destroy()
		phantomFrame = nil
	end
	local p = s and s.phantom
	if not p or not isOpen then
		return
	end
	local z = zTop + 100
	local x = math.clamp(math.floor(p.x * W), SPACE.s, math.max(SPACE.s, W - PHANTOM_W - SPACE.s))
	local y = math.clamp(math.floor(p.y * H), SPACE.s, math.max(SPACE.s, H - TB - PHANTOM_H - 56))
	local f = UiKit.frame({ Name = "Phantom", Size = UDim2.fromOffset(PHANTOM_W, PHANTOM_H), Position = UDim2.fromOffset(x, y), BorderSizePixel = 1, BorderColor3 = C.edge, ZIndex = z, Parent = windowsLayer })
	UiKit.bevel(f)
	local bar = UiKit.frame({ Name = "Bar", Size = UDim2.new(1, -6, 0, 24), Position = UDim2.fromOffset(3, 3), BackgroundColor3 = D.phantom1, ZIndex = z + 1, Parent = f })
	UiKit.new("UIGradient", { Color = ColorSequence.new(D.phantom1, D.phantom2), Parent = bar })
	UiKit.button({
		name = "PhantomClose",
		text = "X",
		size = UDim2.fromOffset(18, 18),
		position = UDim2.fromOffset(3, 3),
		parent = bar,
		zindex = z + 3,
		textSize = 16,
		font = UiKit.FONT_PIXEL,
		onClick = function()
			send("phantom", p.id, "close")
		end,
	})
	UiKit.text("title", { Text = "SecureErase [Not Responding]", Size = UDim2.new(1, -32, 1, 0), Position = UDim2.fromOffset(28, 0), TextColor3 = D.phantomText, TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = z + 2, Parent = bar })
	UiKit.text("mono", { Text = "THE QUEUE MUST BE FINISHED.\nDO NOT READ THE FILES.\nPress OK to continue.", Size = UDim2.new(1, -28, 0, 72), Position = UDim2.fromOffset(14, 40), TextYAlignment = Enum.TextYAlignment.Top, ZIndex = z + 2, Parent = f })
	UiKit.button({
		text = "OK",
		size = UDim2.fromOffset(96, 30),
		position = UDim2.new(0.5, -48, 1, -42),
		parent = f,
		zindex = z + 2,
		onClick = function()
			send("phantom", p.id, "ok")
		end,
	})
	if p.first then
		local tip = UiKit.text("body", {
			Text = "Not a real dialog: red title bar, X on the LEFT. Close it with that X.",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Position = UDim2.new(0, 0, 1, SPACE.s),
			BackgroundTransparency = 0,
			BackgroundColor3 = D.tip,
			ZIndex = z + 2,
			Parent = f,
		})
		UiKit.stroke(tip, C.edge, 0, 1)
		UiKit.padding(tip, SPACE.s, SPACE.xs)
	end
	phantomFrame = f
end

-- Snapshot-driven chrome -----------------------------------------------------

local function renderTray(snap: Types.Snapshot)
	local doorOk = snap.door == "Latched"
	local powerOk = snap.power.workstation and snap.power.lights
	taskbarTray.erased.Text = string.format("ERASED %d/%d", snap.erased, snap.total)
	taskbarTray.door.Text = if doorOk then "DOOR OK" else "DOOR OPEN!"
	taskbarTray.door.TextColor3 = if doorOk then C.text else C.bad
	taskbarTray.power.Text = if powerOk then "PWR OK" else "PWR FAULT"
	taskbarTray.power.TextColor3 = if powerOk then C.text else C.bad
	taskbarTray.clock.Text = State.nightClock(snap.nightMinutes)
	chinLed.BackgroundColor3 = if snap.power.workstation then D.led else C.amber
end

local function showToast(from: string, text: string)
	toastFrom.Text = from
	toastText.Text = text
	toast.Visible = true
	local rest = UDim2.new(1, -SPACE.s, 1, -(TB + SPACE.s))
	toast.Position = rest + UDim2.fromOffset(0, SPACE.l)
	TweenService:Create(toast, UiKit.POP, { Position = rest }):Play()
	local stamp = os.clock()
	toast:SetAttribute("Stamp", stamp)
	task.delay(7, function()
		if toast:GetAttribute("Stamp") == stamp then
			toast.Visible = false
		end
	end)
end

local function placeFragment(win: UiKit.Window)
	win.frame.Position = UDim2.fromOffset(math.max(SPACE.s, (W - FRAG_W) // 2), math.max(SPACE.xs, (H - TB - FRAG_H) // 2))
end

local function showFragment(index: number)
	local f = Dialogue.FRAGMENTS[index]
	if not f or not isOpen then
		return
	end
	if fragmentWin then
		fragmentWin.frame:Destroy()
	end
	local win = UiKit.window(windowsLayer, f.title, UDim2.fromOffset(FRAG_W, FRAG_H), UDim2.new(), 300, function()
		if fragmentWin then
			fragmentWin.frame:Destroy()
			fragmentWin = nil
			refreshActive()
		end
	end)
	win.frame.Name = "Fragment"
	fragmentWin = win
	placeFragment(win)
	trackWindow(win)
	local paper = UiKit.frame({ Name = "Paper", Size = UDim2.fromScale(1, 1), BackgroundColor3 = D.paper, ZIndex = 303, Parent = win.body })
	UiKit.bevel(paper, true)
	local col = UiKit.frame({ Name = "Text", Size = UDim2.new(1, -2 * SPACE.l, 1, -2 * SPACE.m), Position = UDim2.fromOffset(SPACE.l, SPACE.m), BackgroundTransparency = 1, ZIndex = 305, Parent = paper })
	UiKit.new("UIListLayout", { Padding = UDim.new(0, SPACE.xs), SortOrder = Enum.SortOrder.LayoutOrder, Parent = col })
	UiKit.text("title", { Text = "RECOVERED BEFORE SHREDDING", Size = UDim2.new(1, 0, 0, 20), TextColor3 = C.textDim, TextWrapped = false, LayoutOrder = 1, ZIndex = 306, Parent = col })
	UiKit.text("body", { Text = f.kind, Font = UiKit.FONT_BOLD, Size = UDim2.new(1, 0, 0, 22), TextColor3 = C.bad, TextWrapped = false, LayoutOrder = 2, ZIndex = 306, Parent = col })
	UiKit.text("letter", { Text = f.body, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, TextYAlignment = Enum.TextYAlignment.Top, LayoutOrder = 3, ZIndex = 306, Parent = col })
	bringToFront(win)
end

-- Layout ----------------------------------------------------------------------

-- Places what depends on the logical canvas size (W x H).
local function layout()
	local workH = H - TB
	local mainY = math.clamp(math.floor((workH - MAIN_H) * 0.3), SPACE.xs, 48)
	mainWin.frame.Position = UDim2.fromOffset(MAIN_X, mainY)
	local sideH = math.clamp(workH - 50, 300, 440)
	for _, w in side do
		w.frame.Size = UDim2.fromOffset(SIDE_W, sideH)
	end
	-- wallpaper mark only where no window sits on it
	local markLeft, markTop = W - SPACE.xl - 320, workH - SPACE.xl - 80
	wallMark.Visible = markLeft >= MAIN_X + MAIN_W or markTop >= mainY + MAIN_H
	-- taskbar: Start, [Leave on compact screens], task buttons when they fit, tray
	local x = 98
	if compact then
		leaveButton.Parent = taskbar
		leaveButton.AnchorPoint = Vector2.zero
		leaveButton.Position = UDim2.fromOffset(x, 4)
		leaveButton.Size = UDim2.fromOffset(LEAVE_TASKBAR_W, 26)
		leaveButton.TextSize = 16
		leaveButton.Text = "Leave computer"
		leaveButton.ZIndex = 502
		x += LEAVE_TASKBAR_W + 4
	end
	local fits = x + #taskButtons * (TASK_W + 4) + SPACE.s + TRAY_W + 4 <= W
	for i, b in taskButtons do
		b.Visible = fits
		b.Position = UDim2.fromOffset(x + (i - 1) * (TASK_W + 4), 4)
	end
	if fragmentWin then
		placeFragment(fragmentWin)
	end
	if phantomFrame then
		renderPhantom()
	end
end

-- Fits the monitor to the viewport and picks the logical desktop size.
local function adapt()
	local vp = gui.AbsoluteSize
	if vp.X < 2 or vp.Y < 2 then
		local cam = workspace.CurrentCamera
		vp = if cam then cam.ViewportSize else Vector2.new(BASE_W, BASE_H)
	end
	-- framed monitor: cream bezel, 3:2, chin below the screen
	local bh = math.min(vp.Y * 0.98, vp.X * 0.98 / 1.5)
	local bw = bh * 1.5
	local sx, sy = bw * 0.95, bh * 0.85
	compact = math.min(sx / BASE_W, sy / BASE_H) < COMPACT_BELOW
	if compact then
		-- short or narrow screens: no bezel, every pixel goes to the desktop
		bw, bh, sx, sy = vp.X, vp.Y, vp.X, vp.Y
	end
	bezel.Size = UDim2.fromOffset(math.floor(bw), math.floor(bh))
	screen.Size = UDim2.fromOffset(math.floor(sx), math.floor(sy))
	screen.Position = if compact then UDim2.new() else UDim2.fromOffset(math.floor(bw * 0.025), math.floor(bh * 0.03))
	screen.BorderSizePixel = if compact then 0 else 3
	local s = math.max(math.min(sx / BASE_W, sy / BASE_H), math.min(1, sx / MIN_W, sy / MIN_H))
	s = math.min(s, MAX_SCALE)
	W, H = math.floor(sx / s), math.floor(sy / s)
	canvasScale.Scale = s
	canvas.Size = UDim2.fromOffset(W, H)
	chin.Visible = not compact
	if not compact then
		local chinTop = bh * 0.03 + sy
		local chinH = bh - chinTop
		chin.Position = UDim2.fromOffset(math.floor(bw / 2), math.floor(chinTop + chinH / 2))
		chin.Size = UDim2.fromOffset(math.floor(sx / s), math.floor(chinH / s))
		chinScale.Scale = s
		leaveButton.Parent = chin
		leaveButton.AnchorPoint = Vector2.new(1, 0.5)
		leaveButton.Position = UDim2.fromScale(1, 0.5)
		leaveButton.Size = UDim2.fromOffset(264, 34)
		leaveButton.TextSize = 16
		leaveButton.Text = "Leave computer   (Space / B)"
		leaveButton.ZIndex = 10
	end
	layout()
end

-- Construction ---------------------------------------------------------------

local function desktopIcon(i: number, label: string, kind: string, onOpen: () -> ()): Frame
	local b = UiKit.new("TextButton", {
		Name = "Icon_" .. label,
		Size = UDim2.fromOffset(ICON_W, ICON_H),
		Position = UDim2.fromOffset(6, 6 + (i - 1) * (ICON_H + 4)),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		Selectable = true,
		SelectionImageObject = UiKit.selectionRing(),
		ZIndex = 2,
		Parent = canvas,
	}) :: TextButton
	local g = glyph(b, kind, (ICON_W - 32) // 2, 2, 2, 3)
	local name = UiKit.text("body", {
		Name = "Label",
		Text = label,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 40),
		Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		TextColor3 = C.white,
		TextStrokeColor3 = C.charcoal,
		TextStrokeTransparency = 0.6,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = false,
		BackgroundColor3 = C.select,
		BackgroundTransparency = 1,
		ZIndex = 4,
		Parent = b,
	})
	UiKit.padding(name, SPACE.xs, 0)
	-- Windows-style focus: the label gets the charcoal-blue selection box
	local function lit(on: boolean)
		name.BackgroundTransparency = if on then 0 else 1
		name.TextStrokeTransparency = if on then 1 else 0.6
	end
	b.MouseEnter:Connect(function()
		lit(true)
	end)
	b.MouseLeave:Connect(function()
		lit(GuiService.SelectedObject == b)
	end)
	b.SelectionGained:Connect(function()
		lit(true)
	end)
	b.SelectionLost:Connect(function()
		lit(false)
	end)
	b.Activated:Connect(function()
		UiKit.click()
		onOpen()
	end)
	return g
end

-- flat start-menu row: icon + label, charcoal-blue highlight with white text
local function menuItem(text: string, kind: string, y: number, onPick: () -> ()): TextButton
	local b = UiKit.new("TextButton", {
		Name = "Item",
		Size = UDim2.new(1, -34, 0, 32),
		Position = UDim2.fromOffset(30, y),
		BackgroundColor3 = C.select,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		Selectable = true,
		SelectionImageObject = UiKit.selectionRing(),
		ZIndex = 602,
		Parent = startMenu,
	}) :: TextButton
	glyph(b, kind, 6, 8, 1, 603)
	local l = UiKit.text("body", { Text = text, Size = UDim2.new(1, -34, 1, 0), Position = UDim2.fromOffset(30, 0), TextWrapped = false, ZIndex = 603, Parent = b })
	local function lit(on: boolean)
		b.BackgroundTransparency = if on then 0 else 1
		l.TextColor3 = if on then C.white else C.text
	end
	b.MouseEnter:Connect(function()
		lit(true)
	end)
	b.MouseLeave:Connect(function()
		lit(GuiService.SelectedObject == b)
	end)
	b.SelectionGained:Connect(function()
		lit(true)
	end)
	b.SelectionLost:Connect(function()
		lit(false)
	end)
	b.Activated:Connect(function()
		UiKit.click()
		onPick()
	end)
	return b
end

-- taskbar button with a small icon and a left-aligned label
local function taskButton(text: string, kind: string, onClick: () -> ()): TextButton
	local b = UiKit.button({ name = "Task_" .. text, text = "", size = UDim2.fromOffset(TASK_W, 26), parent = taskbar, zindex = 502, onClick = onClick })
	glyph(b, kind, 6, 5, 1, 503)
	UiKit.text("button", { Text = text, Size = UDim2.new(1, -30, 1, 0), Position = UDim2.fromOffset(26, 0), TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 503, Parent = b })
	table.insert(taskButtons, b)
	return b
end

local function unreadMark(parent: Instance, x: number, y: number, z: number)
	table.insert(unreadMarks, UiKit.frame({ Name = "Unread", Size = UDim2.fromOffset(10, 10), Position = UDim2.fromOffset(x, y), BackgroundColor3 = C.amber, BorderSizePixel = 1, BorderColor3 = C.edge, Visible = false, ZIndex = z, Parent = parent }))
end

local function build()
	gui = UiKit.new("ScreenGui", {
		Name = "Desktop",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 5,
		Enabled = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
	-- the monitor: square cream plastic, recessed screen, chin with controls
	bezel = UiKit.frame({ Name = "Bezel", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.98, 0.98), BackgroundColor3 = D.plastic, Parent = gui })
	screen = UiKit.frame({ Name = "Screen", BackgroundColor3 = Color3.new(0, 0, 0), BorderColor3 = D.plasticDark, ClipsDescendants = true, Parent = bezel })
	canvas = UiKit.frame({ Name = "Canvas", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(W, H), BackgroundColor3 = C.desktop, Parent = screen })
	canvasScale = UiKit.new("UIScale", { Parent = canvas })
	UiKit.new("UIGradient", { Color = ColorSequence.new(D.wallTop, D.wallBottom), Rotation = 90, Parent = canvas })

	-- wallpaper mark, low contrast
	wallMark = UiKit.frame({ Name = "Wallpaper", Size = UDim2.fromOffset(320, 80), AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -SPACE.xl, 1, -(TB + SPACE.xl)), BackgroundTransparency = 1, Parent = canvas })
	UiKit.text("display", { Text = "MRR", TextSize = 48, Size = UDim2.new(1, 0, 0, 48), TextColor3 = D.wallMark, TextXAlignment = Enum.TextXAlignment.Right, TextWrapped = false, Parent = wallMark })
	UiKit.text("body", { Text = Dialogue.COMPANY, Size = UDim2.new(1, 0, 0, 20), Position = UDim2.fromOffset(0, 54), TextColor3 = D.wallMark, TextXAlignment = Enum.TextXAlignment.Right, TextWrapped = false, Parent = wallMark })

	-- desktop icons
	desktopIcon(1, "SecureErase", "erase", function()
		bringToFront(mainWin)
	end)
	local imGlyph = desktopIcon(2, "Messenger", "messenger", function()
		openSide("Messenger")
	end)
	unreadMark(imGlyph, 26, -2, 6)
	desktopIcon(3, "My Files", "folder", function()
		openSide("Files")
	end)
	desktopIcon(4, "Drive Info", "drive", function()
		openSide("DriveInfo")
	end)
	desktopIcon(5, "Procedures", "text", function()
		openSide("Procedures")
	end)

	windowsLayer = UiKit.frame({ Name = "Windows", Size = UDim2.new(1, 0, 1, -TB), BackgroundTransparency = 1, ZIndex = 10, Parent = canvas })

	-- main SecureErase window (always open). Body is 648 x 380:
	-- header 0-20 | progress 22-34 | instructions 38-76 | game 78-328 | feedback 332-352 | hint 354-380
	mainWin = UiKit.window(windowsLayer, "SecureErase 2.1", UDim2.fromOffset(MAIN_W, MAIN_H), UDim2.fromOffset(MAIN_X, SPACE.s), 20, nil)
	mainWin.frame.Name = "MainWindow"
	trackWindow(mainWin)
	local body = mainWin.body
	local z = 24
	local header = UiKit.text("heading", { Name = "Header", Text = "", Size = UDim2.new(1, -(STAGE_W + SPACE.xs), 0, 20), TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = z, Parent = body })
	local stage = UiKit.text("title", {
		Name = "Stage",
		Text = "",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(STAGE_W, 20),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextWrapped = false,
		ZIndex = z,
		Parent = body,
	})
	local _, fill = UiKit.progress(body, UDim2.new(1, 0, 0, 12), UDim2.fromOffset(0, 22), z)
	local instructions = UiKit.text("body", { Name = "Instructions", Text = "", Size = UDim2.new(1, 0, 0, 38), Position = UDim2.fromOffset(0, 38), TextYAlignment = Enum.TextYAlignment.Top, ZIndex = z, Parent = body })
	local gameArea = UiKit.frame({ Name = "Game", Size = UDim2.fromOffset(GAME_W, GAME_H), Position = UDim2.fromOffset((MAIN_W - 12 - GAME_W) // 2, 78), BackgroundTransparency = 1, ZIndex = z, Parent = body })
	local feedback = UiKit.text("body", { Name = "Feedback", Text = "", Font = UiKit.FONT_BOLD, Size = UDim2.new(1, 0, 0, 20), Position = UDim2.fromOffset(0, 332), TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = z, Parent = body })
	local hintBox = UiKit.frame({ Name = "HintBox", Size = UDim2.new(1, 0, 0, 26), Position = UDim2.fromOffset(0, 354), BackgroundColor3 = D.tip, BorderSizePixel = 1, BorderColor3 = D.tipLine, BorderMode = Enum.BorderMode.Inset, Visible = false, ZIndex = z, Parent = body })
	-- hints are one line; scaled text keeps a rare long one inside the strip (13 px floor)
	local hint = UiKit.text("body", { Name = "Hint", Text = "", Size = UDim2.new(1, -2 * SPACE.s, 1, 0), Position = UDim2.fromOffset(SPACE.s, 0), TextScaled = true, ZIndex = z + 1, Parent = hintBox })
	-- power loss: the job area goes dark with a short system notice
	local overlay = UiKit.frame({ Name = "NoPower", Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.charcoal, BackgroundTransparency = 0.06, ZIndex = 60, Visible = false, Parent = body })
	UiKit.text("title", { Text = "DEVICE NOT READY", TextSize = 24, Size = UDim2.new(1, 0, 0, 28), Position = UDim2.new(0, 0, 0.5, -84), TextColor3 = C.amber, TextXAlignment = Enum.TextXAlignment.Center, TextWrapped = false, ZIndex = 61, Parent = overlay })
	local overlayText = UiKit.text("body", {
		Text = "",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, -44),
		Size = UDim2.fromOffset(520, 60),
		TextColor3 = C.hudText,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Top,
		ZIndex = 61,
		Parent = overlay,
	})
	UiKit.text("body", { Text = "Your progress is saved.", Size = UDim2.new(1, 0, 0, 20), Position = UDim2.new(0, 0, 0.5, 28), TextColor3 = C.hudDim, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 61, Parent = overlay })
	mainParts = {
		header = header,
		stage = stage,
		progressFill = fill,
		instructions = instructions,
		game = gameArea,
		feedback = feedback,
		hintBox = hintBox,
		hint = hint,
		overlay = overlay,
		overlayText = overlayText,
	}

	-- side windows, cascaded from the right edge
	local sideDefs = {
		{ "Messenger", "MRR Messenger - R. Kessler" },
		{ "Files", "My Files - C:\\RECOVERED" },
		{ "DriveInfo", "Drive Manager" },
		{ "Procedures", "Procedures.txt - Notepad" },
	}
	for i, def in sideDefs do
		local nm = def[1]
		local x = SIDE_W + SPACE.s + (#sideDefs - i) * 16
		local w = UiKit.window(windowsLayer, def[2], UDim2.fromOffset(SIDE_W, 380), UDim2.new(1, -x, 0, 6 + (i - 1) * 12), 30 + i * 10, function()
			closeSide(nm)
		end)
		w.frame.Visible = false
		w.frame.Name = "Side_" .. nm
		trackWindow(w)
		side[nm] = w
	end

	-- taskbar: cream face, Start, task buttons, sunken tray with the clock
	taskbar = UiKit.frame({ Name = "Taskbar", Size = UDim2.new(1, 0, 0, TB), Position = UDim2.new(0, 0, 1, -TB), BackgroundColor3 = C.face, ZIndex = 500, Parent = canvas })
	UiKit.frame({ Name = "Edge", Size = UDim2.new(1, 0, 0, 2), BackgroundColor3 = C.faceLight, ZIndex = 501, Parent = taskbar })
	startBtn = UiKit.button({
		name = "Start",
		text = "",
		size = UDim2.fromOffset(90, 26),
		position = UDim2.fromOffset(4, 4),
		parent = taskbar,
		zindex = 502,
		onClick = function()
			setStartMenu(not startMenu.Visible)
		end,
	})
	glyph(startBtn, "logo", 7, 5, 1, 503)
	UiKit.text("title", { Text = "START", Size = UDim2.new(1, -28, 1, 0), Position = UDim2.fromOffset(28, 0), TextWrapped = false, ZIndex = 503, Parent = startBtn })
	taskButton("SecureErase", "erase", function()
		bringToFront(mainWin)
	end)
	local imTask = taskButton("Messenger", "messenger", function()
		openSide("Messenger")
	end)
	unreadMark(imTask, TASK_W - 14, 4, 504)
	local tray = UiKit.frame({ Name = "Tray", Size = UDim2.fromOffset(TRAY_W, 26), AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -4, 0, 4), BackgroundColor3 = D.well, ZIndex = 502, Parent = taskbar })
	UiKit.bevel(tray, true)
	local trayItems = UiKit.frame({ Name = "Items", Size = UDim2.new(1, -2 * SPACE.s, 1, 0), Position = UDim2.fromOffset(SPACE.s, 0), BackgroundTransparency = 1, ZIndex = 504, Parent = tray })
	UiKit.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, SPACE.m),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = trayItems,
	})
	local function trayLabel(order: number): TextLabel
		return UiKit.text("title", { Text = "", Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, TextWrapped = false, LayoutOrder = order, ZIndex = 505, Parent = trayItems })
	end
	taskbarTray = {
		erased = trayLabel(1),
		door = trayLabel(2),
		power = trayLabel(3),
		clock = trayLabel(5),
	}
	UiKit.frame({ Name = "Divider", Size = UDim2.fromOffset(2, 18), BackgroundColor3 = C.faceDark, LayoutOrder = 4, ZIndex = 505, Parent = trayItems })

	-- start menu, opening upward from the taskbar
	local items: { { any } } = {
		{ "SecureErase", "erase", function()
			setStartMenu(false)
			bringToFront(mainWin)
		end },
		{ "Messenger", "messenger", function()
			openSide("Messenger")
		end },
		{ "My Files", "folder", function()
			openSide("Files")
		end },
		{ "Drive Info", "drive", function()
			openSide("DriveInfo")
		end },
		{ "Procedures.txt", "text", function()
			openSide("Procedures")
		end },
		{ "Leave computer", "door", function()
			setStartMenu(false)
			Desktop.leave()
		end },
	}
	local menuH = 8 + #items * 32 + 9
	startMenu = UiKit.frame({ Name = "StartMenu", Size = UDim2.fromOffset(224, menuH), AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 2, 1, -TB), BorderSizePixel = 1, BorderColor3 = C.edge, Visible = false, ZIndex = 600, Parent = canvas })
	UiKit.bevel(startMenu)
	local banner = UiKit.frame({ Name = "Banner", Size = UDim2.new(0, 24, 1, -6), Position = UDim2.fromOffset(3, 3), BackgroundColor3 = C.title1, ZIndex = 601, Parent = startMenu })
	UiKit.new("UIGradient", { Color = ColorSequence.new(C.title2, C.title1), Rotation = 90, Parent = banner })
	local y = 4
	for i, it in items do
		if i == #items then
			UiKit.frame({ Name = "Separator", Size = UDim2.new(1, -40, 0, 2), Position = UDim2.fromOffset(34, y + 3), BackgroundColor3 = C.faceDark, ZIndex = 602, Parent = startMenu })
			y += 9
		end
		local b = menuItem(it[1], it[2], y, it[3])
		if i == 1 then
			firstMenuItem = b
		end
		y += 32
	end

	-- message notification above the tray; click opens the messenger
	toast = UiKit.new("TextButton", {
		Name = "Toast",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(320, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -SPACE.s, 1, -(TB + SPACE.s)),
		BackgroundColor3 = C.face,
		BorderSizePixel = 0,
		SelectionImageObject = UiKit.selectionRing(),
		Visible = false,
		ZIndex = 700,
		Parent = canvas,
	}) :: TextButton
	UiKit.stroke(toast, C.edge, 0, 1)
	UiKit.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = toast })
	local toastBar = UiKit.frame({ Name = "Bar", Size = UDim2.new(1, 0, 0, 22), BackgroundColor3 = C.title1, LayoutOrder = 1, ZIndex = 701, Parent = toast })
	UiKit.new("UIGradient", { Color = ColorSequence.new(C.title1, C.title2), Parent = toastBar })
	glyph(toastBar, "messenger", 4, 3, 1, 702)
	UiKit.text("title", { Text = "NEW MESSAGE", Size = UDim2.new(1, -28, 1, 0), Position = UDim2.fromOffset(26, 0), TextColor3 = C.white, TextWrapped = false, ZIndex = 702, Parent = toastBar })
	local toastBody = UiKit.frame({ Name = "Body", Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 2, ZIndex = 701, Parent = toast })
	UiKit.padding(toastBody, SPACE.s)
	UiKit.new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = toastBody })
	toastFrom = UiKit.text("body", { Text = "", Font = UiKit.FONT_BOLD, Size = UDim2.new(1, 0, 0, 20), TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd, LayoutOrder = 1, ZIndex = 702, Parent = toastBody })
	toastText = UiKit.text("body", { Text = "", Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, TextYAlignment = Enum.TextYAlignment.Top, LayoutOrder = 2, ZIndex = 702, Parent = toastBody })
	toast.Activated:Connect(function()
		toast.Visible = false
		openSide("Messenger")
	end)

	-- CRT: very faint scanlines and edge falloff, kept readable
	local scan = UiKit.frame({ Name = "Scanlines", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 900, Parent = screen })
	for i = 0, 59 do
		UiKit.frame({ Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromScale(0, i / 60), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.95, ZIndex = 900, Parent = scan })
	end
	local vignette = UiKit.frame({ Name = "Vignette", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), ZIndex = 901, Parent = screen })
	UiKit.new("UIGradient", {
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.72), NumberSequenceKeypoint.new(0.08, 1), NumberSequenceKeypoint.new(0.92, 1), NumberSequenceKeypoint.new(1, 0.72) }),
		Parent = vignette,
	})
	-- black frame that fades out when the session starts (screen powering on)
	powerOn = UiKit.frame({ Name = "PowerOn", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 1, ZIndex = 950, Parent = screen })

	-- bezel chin (framed monitors only): model badge, power LED, leave button.
	-- Laid out in logical px and scaled like the desktop.
	chin = UiKit.frame({ Name = "Chin", AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, ZIndex = 5, Parent = bezel })
	chinScale = UiKit.new("UIScale", { Parent = chin })
	UiKit.text("title", { Text = "MRR-900", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(84, 20), TextColor3 = D.plasticDark, TextWrapped = false, ZIndex = 6, Parent = chin })
	chinLed = UiKit.frame({ Name = "PowerLed", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 92, 0.5, 0), Size = UDim2.fromOffset(8, 8), BackgroundColor3 = D.led, BorderSizePixel = 1, BorderColor3 = D.plasticDark, ZIndex = 6, Parent = chin })
	leaveButton = UiKit.button({
		name = "LeaveComputer",
		text = "Leave computer",
		size = UDim2.fromOffset(LEAVE_TASKBAR_W, 26),
		parent = chin,
		color = C.burgundy,
		textColor = C.hudText,
		zindex = 10,
		onClick = function()
			Desktop.leave()
		end,
	})
	leaveButton.TextWrapped = false

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(adapt)
	local cam = workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(adapt)
	end
	adapt()
	refreshActive()
end

-- Open / close ---------------------------------------------------------------

local function onLeaveAction(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		Desktop.leave()
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

-- Roblox chat would sit on top of the desktop and steal clicks while seated.
local chatWasEnabled: boolean? = nil
local function setChatVisible(visible: boolean)
	pcall(function()
		local TextChatService = game:GetService("TextChatService")
		local win = TextChatService:FindFirstChildOfClass("ChatWindowConfiguration")
		if win then
			if not visible then
				chatWasEnabled = win.Enabled
				win.Enabled = false
			elseif chatWasEnabled ~= nil then
				win.Enabled = chatWasEnabled
				chatWasEnabled = nil
			end
		end
	end)
end

local function open()
	if isOpen then
		return
	end
	isOpen = true
	-- the desktop needs the pointer (WorkstationCamera applies Cursor state)
	Cursor.request("desktop", true)
	setChatVisible(false)
	gui.Enabled = true
	adapt()
	refreshActive()
	powerOn.BackgroundTransparency = 0
	TweenService:Create(powerOn, UiKit.FADE, { BackgroundTransparency = 1 }):Play()
	ContextActionService:BindActionAtPriority("NS_LeaveComputer", onLeaveAction, false, 3000, Enum.KeyCode.ButtonB, Enum.KeyCode.Backspace)
	GuiService.SelectedObject = leaveButton
	task.defer(function()
		if not isOpen then
			return
		end
		adapt()
		local start = mainParts.game:FindFirstChildWhichIsA("GuiButton", true)
		if start then
			GuiService.SelectedObject = start
		end
	end)
end

local function close()
	if not isOpen then
		return
	end
	isOpen = false
	gui.Enabled = false
	Cursor.request("desktop", false)
	setChatVisible(true)
	startMenu.Visible = false
	ContextActionService:UnbindAction("NS_LeaveComputer")
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(gui) then
		GuiService.SelectedObject = nil
	end
	for name in sideOpen do
		closeSide(name)
	end
	if fragmentWin then
		fragmentWin.frame:Destroy()
		fragmentWin = nil
	end
	if phantomFrame then
		phantomFrame:Destroy()
		phantomFrame = nil
	end
end

function Desktop.isOpen(): boolean
	return isOpen
end

-- Standing up must return control instantly, even before the server answers.
function Desktop.forceClose()
	session = nil
	close()
end

function Desktop.init()
	build()
	State.SessionChanged:Connect(function(payload)
		if not payload.active then
			session = nil
			close()
			return
		end
		session = payload
		open()
		renderMain()
		renderPhantom()
	end)
	State.Changed:Connect(function(snap)
		renderTray(snap)
		if not isOpen then
			return
		end
		for name, isOpenNow in sideOpen do
			if isOpenNow and name ~= "Files" and name ~= "Procedures" then
				local key = sideKey(name, snap)
				if sideKeys[name] ~= key then
					sideKeys[name] = key
					renderSide(name)
				end
			end
		end
		-- the finale screens and the no-power overlay are snapshot-driven
		local finale = snap.phase == "FinalPurge" or snap.phase == "SignOff" or snap.phase == "ClockOut"
		if finale or lastViewKey == "finale" then
			local sig = finaleSignature(snap)
			if sig ~= finaleKey then
				finaleKey = sig
				renderMain()
			end
		elseif lastViewKey == "nodrive" or mainParts.overlay.Visible ~= (not snap.power.workstation) then
			renderMain()
		end
	end)
	State.Fx:Connect(function(name, data)
		if name == "BossMessage" and isOpen then
			showToast(data.from, data.text)
			if sideOpen.Messenger then
				renderSide("Messenger")
			else
				setUnread(true)
			end
		elseif name == "Fragment" and isOpen then
			showFragment(data.index)
		end
	end)
	-- the character can die / be reset while seated: close immediately
	player.CharacterRemoving:Connect(function()
		session = nil
		close()
	end)
	local _ = Config
end

return Desktop
