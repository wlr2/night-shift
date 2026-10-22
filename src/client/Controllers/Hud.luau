--!strict
-- On-screen HUD while walking: objective, live threats, crew status, toasts
-- and pager lines, carry hint, controls line and the centre dot, plus the
-- downed / restore / ending overlays and the loading card.
-- Square dark plates and the type roles from docs/ART_DIRECTION.md. Text keeps
-- fixed pixel sizes (never below UiKit.MIN_TEXT) inside scale-width columns;
-- one UIScale per column grows the HUD on tall screens (phones stay at 1).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Dialogue = require(ReplicatedStorage.Shared.Dialogue)
local Types = require(ReplicatedStorage.Shared.Types)
local State = require(script.Parent.State)
local Desktop = require(script.Parent.Desktop)
local UiKit = require(script.Parent.Parent.Ui.UiKit)
local Cursor = require(script.Parent.Parent.Ui.Cursor)

local player = Players.LocalPlayer
local C = UiKit.C
local SPACE = UiKit.SPACE

local Hud = {}

-- HUD scale = viewport height / REF_HEIGHT, clamped to [1, SCALE_MAX].
-- Set SCALE_MAX to 1 to keep every screen at the nominal pixel sizes.
local REF_HEIGHT = 1080
local SCALE_MAX = 1.5
local EDGE = SPACE.m -- margin from the screen edges
-- The interaction prompt card (PromptUi) sits at 60% of the screen height and
-- is up to ~84 px tall; the bottom column drops its oldest toasts to stay clear.
local PROMPT_Y = 0.6
local PROMPT_CLEAR = 92

-- text tints that read on the dark plates
local ALERT = Color3.fromRGB(236, 116, 102)
local OK = Color3.fromRGB(150, 204, 160)
local ALERT_PLATE = Color3.fromRGB(46, 20, 22)
local ALERT_FLASH = Color3.fromRGB(128, 34, 30)
local CARD_TEXT = Color3.fromRGB(226, 218, 198)

type ThreatRow = { frame: Frame, label: TextLabel, urgent: boolean, tweens: { Tween } }
type TeamRow = { frame: Frame, name: TextLabel, status: TextLabel }
type HintKey = { cap: Frame, letter: TextLabel, kbm: string, pad: string }

export type ToastOpts = {
	tag: string?, -- short pixel label above the text (PAGER, CHECKPOINT ...)
	speaker: string?, -- who is talking, next to the tag
	dialogue: boolean?, -- boss lines and other speech use the dialogue role
	seconds: number?,
}

local gui: ScreenGui
local top: ScreenGui
local leftCol: Frame
local rightCol: Frame
local bottomCol: Frame
local scales: { UIScale } = {}

local objectivePanel: Frame
local objectiveText: TextLabel
local clockText: TextLabel
local erasedText: TextLabel
local crewText: TextLabel
local progressFill: Frame

local threatList: Frame
local threatRows: { [string]: ThreatRow } = {}
local teamPanel: Frame
local teamRows: { [Player]: TeamRow } = {}

local toastStack: Frame
local toasts: { Frame } = {}
local toastSeq = 0

local carryPlate: Frame
local carryItem: TextLabel
local carryHow: TextLabel

local hints: Frame
local hintDrive: Frame
local hintKeys: { HintKey } = {}

local dot: Frame
local downedOverlay: Frame
local downedTitle: TextLabel
local downedText: TextLabel
local fade: Frame
local fadeTitle: TextLabel
local fadeText: TextLabel
local ending: Frame
local endingCol: Frame
local endingStats: TextLabel
local loading: Frame

local function scaled(f: GuiObject)
	table.insert(scales, UiKit.new("UIScale", { Parent = f }) :: UIScale)
end

local function rescale()
	local cam = workspace.CurrentCamera
	local s = if cam then math.clamp(cam.ViewportSize.Y / REF_HEIGHT, 1, SCALE_MAX) else 1
	for _, u in scales do
		u.Scale = s
	end
end

local function list(parent: Instance, gap: number, props: UiKit.Props?)
	local p: UiKit.Props = if props then table.clone(props) else {}
	p.Padding = UDim.new(0, gap)
	p.SortOrder = Enum.SortOrder.LayoutOrder
	p.Parent = parent
	UiKit.new("UIListLayout", p)
end

-- Invisible column that stacks plates and grows to fit them.
local function column(name: string, anchor: Vector2, pos: UDim2, width: number, minW: number, maxW: number, parent: Instance): Frame
	local f = UiKit.frame({ Name = name, AnchorPoint = anchor, Position = pos, Size = UDim2.fromScale(width, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = parent })
	UiKit.new("UISizeConstraint", { MinSize = Vector2.new(minW, 0), MaxSize = Vector2.new(maxW, math.huge), Parent = f })
	scaled(f)
	return f
end

-- Transparent full-width strip inside a plate (header / footer lines).
local function strip(parent: Instance, height: number, order: number): Frame
	return UiKit.frame({ Name = "Strip", Size = UDim2.new(1, 0, 0, height), BackgroundTransparency = 1, LayoutOrder = order, Parent = parent })
end

local function setStroke(plate: GuiObject, color: Color3, transparency: number)
	local s = plate:FindFirstChildOfClass("UIStroke")
	if s then
		s.Color = color
		s.Transparency = transparency
	end
end

-- Fades every plate, outline and label under `root` (and root) to invisible.
local function fadeOut(root: GuiObject, seconds: number)
	local info = TweenInfo.new(seconds)
	local all = root:GetDescendants()
	table.insert(all, root)
	for _, d in all do
		if d:IsA("TextLabel") then
			TweenService:Create(d, info, { TextTransparency = 1, BackgroundTransparency = 1 }):Play()
		elseif d:IsA("GuiObject") then
			TweenService:Create(d, info, { BackgroundTransparency = 1 }):Play()
		elseif d:IsA("UIStroke") then
			TweenService:Create(d, info, { Transparency = 1 }):Play()
		end
	end
end

local function esc(s: string): string
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function sentence(s: string): string
	return string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2)
end

local function viewportHeight(): number
	local cam = workspace.CurrentCamera
	return if cam then cam.ViewportSize.Y else 720
end

---------------------------------------------------------------------------
-- Toasts: system notices, pager lines, checkpoints

local function dropToast(f: Frame)
	local i = table.find(toasts, f)
	if i then
		table.remove(toasts, i)
	end
	f:Destroy()
	toastStack.Visible = #toasts > 0
end

-- One frame at a time so each check reads the re-laid-out column. The
-- newest toast always stays (on phones it may tuck under the prompt card,
-- which draws on top).
local trimming = false
local function trimToasts()
	if trimming then
		return
	end
	trimming = true
	task.spawn(function()
		task.wait()
		while #toasts > 1 and toastStack.Parent == bottomCol and bottomCol.AbsoluteSize.Y > viewportHeight() * (1 - PROMPT_Y) - EDGE - PROMPT_CLEAR do
			dropToast(toasts[1])
			task.wait()
		end
		trimming = false
	end)
end

function Hud.toast(text: string, kind: string?, opts: ToastOpts?)
	local o: ToastOpts = opts or {}
	local accent = if kind == "bad" then C.bad elseif kind == "good" then C.good else C.slate
	local tagColor = if kind == "bad" then ALERT elseif kind == "good" then OK else C.amber
	local tag = o.tag or (if kind == "bad" then "WARNING" else nil)
	toastSeq += 1

	local f = UiKit.frame({ Name = "Toast", Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = C.hud, BackgroundTransparency = 0.18, LayoutOrder = toastSeq, Parent = toastStack })
	UiKit.stroke(f)
	UiKit.frame({ Name = "Accent", Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = accent, Parent = f })
	local body = UiKit.frame({ Name = "Body", Position = UDim2.fromOffset(3, 0), Size = UDim2.new(1, -3, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = f })
	UiKit.padding(body, SPACE.m, SPACE.s)
	list(body, 2)
	if tag or o.speaker then
		local head = strip(body, 16, 1)
		list(head, SPACE.s, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center })
		if tag then
			UiKit.text("title", { Text = tag, Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, TextWrapped = false, TextColor3 = tagColor, LayoutOrder = 1, Parent = head })
		end
		if o.speaker then
			UiKit.text("caption", { Text = o.speaker, Font = UiKit.FONT_BOLD, Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, TextWrapped = false, TextColor3 = C.hudDim, LayoutOrder = 2, Parent = head })
		end
	end
	UiKit.text(if o.dialogue then "dialogue" else "body", {
		Name = "Text",
		Text = text,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextColor3 = C.hudText,
		LayoutOrder = 2,
		Parent = body,
	})

	table.insert(toasts, f)
	toastStack.Visible = true
	local keep = if viewportHeight() < 600 then 2 else 3
	while #toasts > keep do
		dropToast(toasts[1])
	end
	trimToasts()
	-- long lines stay up long enough to read
	local seconds = o.seconds or math.clamp(2.5 + #text / 15, 5, 9)
	task.delay(seconds, function()
		if f.Parent then
			fadeOut(f, 0.35)
			task.wait(0.4)
			dropToast(f)
		end
	end)
end

---------------------------------------------------------------------------
-- Threats: counterplay cues, urgent first. Urgent plates carry a "!" badge,
-- a red outline that pulses and sort to the top; warnings carry an "i" badge,
-- so the two never differ by colour alone.

local function dropThreat(id: string)
	local r = threatRows[id]
	if r then
		for _, tw in r.tweens do
			tw:Cancel()
		end
		r.frame:Destroy()
		threatRows[id] = nil
	end
end

local function threatRow(t: Types.ThreatInfo): ThreatRow
	local urgent = t.urgent
	local plate = UiKit.frame({
		Name = "Threat",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = if urgent then ALERT_FLASH else C.hud,
		BackgroundTransparency = if urgent then 0.1 else 0.22,
		Parent = threatList,
	})
	local stroke = UiKit.stroke(plate, if urgent then C.bad else C.hudLine, if urgent then 0 else 0.45)
	-- offset height synced to the plate: a scale height inside an
	-- AutomaticSize parent feeds back and grows the plate every frame
	local badge = UiKit.frame({ Name = "Badge", Size = UDim2.fromOffset(22, 20), BackgroundColor3 = if urgent then C.bad else C.warn, Parent = plate })
	local function syncBadge()
		local y = plate.AbsoluteSize.Y
		if y ~= y or y < 0 or y > 4096 then
			return
		end
		local hgt = math.floor(y + 0.5)
		if math.abs(badge.Size.Y.Offset - hgt) >= 1 then
			badge.Size = UDim2.fromOffset(22, hgt)
		end
	end
	plate:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncBadge)
	task.defer(syncBadge)
	UiKit.text("key", {
		Text = if urgent then "!" else "i",
		Size = UDim2.fromScale(1, 1),
		TextColor3 = if urgent then C.white else C.hud,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = badge,
	})
	local label = UiKit.text("body", {
		Name = "Text",
		Text = "",
		RichText = true,
		Position = UDim2.fromOffset(22, 0),
		Size = UDim2.new(1, -22, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextColor3 = C.hudText,
		Parent = plate,
	})
	UiKit.padding(label, SPACE.s, SPACE.xs + 1)
	local tweens: { Tween } = {}
	if urgent then
		-- arrival flash, then a slow pulse on the outline and badge
		TweenService:Create(plate, TweenInfo.new(0.9), { BackgroundColor3 = ALERT_PLATE }):Play()
		local pulse = TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
		tweens = { TweenService:Create(stroke, pulse, { Transparency = 0.7 }), TweenService:Create(badge, pulse, { BackgroundTransparency = 0.35 }) }
		for _, tw in tweens do
			tw:Play()
		end
	end
	return { frame = plate, label = label, urgent = urgent, tweens = tweens }
end

local function threatText(t: Types.ThreatInfo): string
	local s = "<b>" .. esc(t.label) .. "</b>"
	if t.where then
		s ..= '  <font color="#' .. C.hudDim:ToHex() .. '">' .. esc(t.where) .. "</font>"
	end
	return s
end

local function renderThreats(snap: Types.Snapshot)
	local seen: { [string]: boolean } = {}
	for i, t in snap.threats do
		seen[t.id] = true
		local r: ThreatRow? = threatRows[t.id]
		if r and r.urgent ~= t.urgent then
			dropThreat(t.id)
			r = nil
		end
		local row: ThreatRow = r or threatRow(t)
		threatRows[t.id] = row
		row.label.Text = threatText(t)
		row.frame.LayoutOrder = if t.urgent then i else 100 + i
	end
	for id in threatRows do
		if not seen[id] then
			dropThreat(id)
		end
	end
	threatList.Visible = next(threatRows) ~= nil
end

---------------------------------------------------------------------------
-- Crew status (hidden when alone on shift)

local function carryShort(carrying: string): string
	return if carrying == "TrashBag" then "TRASH BAG" elseif carrying == "Printout" then "PRINTOUT" else string.upper(carrying)
end

local function crewStatus(p: Player, snap: Types.Snapshot): (string, Color3)
	local carrying = p:GetAttribute("Carrying")
	if p:GetAttribute("Downed") == true then
		return "CAUGHT", ALERT
	elseif p:GetAttribute("Escaped") == true then
		return "OUTSIDE", OK
	elseif p:GetAttribute("ClockedOut") == true then
		return "CLOCKED OUT", C.hudDim
	elseif snap.operator == p.DisplayName then
		return "AT PC", C.amber
	elseif typeof(carrying) == "string" then
		return carryShort(carrying), C.hudText
	end
	return "", C.hudDim
end

local function teamRow(p: Player): TeamRow
	local f = UiKit.frame({ Name = "Row", Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, Parent = teamPanel })
	list(f, SPACE.s, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center })
	local name = UiKit.text("caption", {
		Text = p.DisplayName,
		Font = UiKit.FONT_BOLD,
		Size = UDim2.fromScale(0, 1),
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = C.hudText,
		LayoutOrder = 1,
		Parent = f,
	})
	UiKit.new("UIFlexItem", { FlexMode = Enum.UIFlexMode.Fill, Parent = name })
	local status = UiKit.text("title", {
		Text = "",
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Right,
		LayoutOrder = 2,
		Parent = f,
	})
	return { frame = f, name = name, status = status }
end

local function renderTeam(snap: Types.Snapshot)
	local players = Players:GetPlayers()
	local present: { [Player]: boolean } = {}
	for i, p in players do
		present[p] = true
		local row = teamRows[p] or teamRow(p)
		teamRows[p] = row
		local text, color = crewStatus(p, snap)
		row.frame.LayoutOrder = i
		row.name.Text = p.DisplayName
		row.name.TextColor3 = if text == "CAUGHT" then ALERT else C.hudText
		row.status.Text = text
		row.status.TextColor3 = color
	end
	for p, row in teamRows do
		if not present[p] then
			row.frame:Destroy()
			teamRows[p] = nil
		end
	end
	teamPanel.Visible = #players > 1
end

---------------------------------------------------------------------------
-- Controls line (keyboard or gamepad glyphs; hidden on touch)

local function inputMode(): string
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Touch then
		return "touch"
	elseif string.find(last.Name, "Gamepad", 1, true) then
		return "pad"
	end
	return "kbm"
end

local function refreshHints()
	local mode = inputMode()
	hints.Visible = mode ~= "touch" and not Desktop.isOpen()
	for _, k in hintKeys do
		local key = if mode == "pad" then k.pad else k.kbm
		k.letter.Text = key
		k.cap.Size = UDim2.fromOffset(20 + (#key - 1) * 10, 20)
	end
end

local function hint(order: number, kbm: string, pad: string, text: string): Frame
	local g = UiKit.frame({ Name = "Hint", Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, LayoutOrder = order, Parent = hints })
	list(g, SPACE.xs + 2, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center })
	local cap = UiKit.keycap(g, kbm, 20)
	cap.LayoutOrder = 1
	local letter = cap:FindFirstChild("Letter")
	if letter and letter:IsA("TextLabel") then
		table.insert(hintKeys, { cap = cap, letter = letter, kbm = kbm, pad = pad })
	end
	UiKit.text("caption", { Text = text, Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, TextWrapped = false, TextColor3 = C.hudDim, LayoutOrder = 2, Parent = g })
	return g
end

---------------------------------------------------------------------------
-- Snapshot rendering

local function carryInfo(carrying: string, snap: Types.Snapshot): (string, string)
	if carrying == "TrashBag" then
		return "Trash bag", "Throw it away at the alley dumpster, out through the rear door."
	elseif carrying == "Printout" then
		return "Printout", "Leave it in the OUT TRAY on the corner desk."
	end
	for _, d in snap.drives do
		if d.id == carrying then
			return d.id .. "  " .. d.name, "Dock it at the corner workstation, or stage it on the drive rack."
		end
	end
	return carrying, "Dock it at the corner workstation, or stage it on the drive rack."
end

local function render(snap: Types.Snapshot)
	local open = Desktop.isOpen()
	objectiveText.Text = snap.objective
	clockText.Text = State.nightClock(snap.nightMinutes)
	erasedText.Text = string.format("ERASED %d/%d", snap.erased, snap.total)
	crewText.Text = if snap.soloMode then "SOLO" else "CREW " .. #Players:GetPlayers()
	progressFill.Size = UDim2.fromScale(if snap.total > 0 then math.clamp(snap.erased / snap.total, 0, 1) else 0, 1)
	renderThreats(snap)
	renderTeam(snap)
	local carrying = player:GetAttribute("Carrying")
	local wasCarrying = carryPlate.Visible
	if typeof(carrying) == "string" then
		local item, how = carryInfo(carrying, snap)
		carryItem.Text = item
		carryHow.Text = how
		carryPlate.Visible = not open
	else
		carryPlate.Visible = false
	end
	if carryPlate.Visible and not wasCarrying then
		trimToasts()
	end
	hintDrive.Visible = typeof(carrying) == "string" and carrying ~= "TrashBag" and carrying ~= "Printout"
	objectivePanel.Visible = not open and snap.objective ~= ""
end

-- Centre dot: first-person aim point while walking only.
local function updateDot()
	dot.Visible = not Cursor.isFree() and not Desktop.isOpen() and player:GetAttribute("Downed") ~= true and not ending.Visible
end

-- Seated at the desktop: objective and walking hints hide; threats and
-- toasts move under the crew panel, top right, clear of the desktop icons.
local function applyMode()
	local open = Desktop.isOpen()
	objectivePanel.Visible = not open and (State.snapshot == nil or State.snapshot.objective ~= "")
	threatList.Parent = if open then rightCol else leftCol
	toastStack.Parent = if open then rightCol else bottomCol
	toastStack.LayoutOrder = if open then 3 else 1
	carryPlate.Visible = not open and typeof(player:GetAttribute("Carrying")) == "string"
	refreshHints()
	updateDot()
end

---------------------------------------------------------------------------
-- Full-screen cards

local function showFade(title: string, text: string, hold: number)
	fade.Visible = true
	fade.BackgroundTransparency = 1
	fadeTitle.Text = title
	fadeText.Text = text
	fadeTitle.TextTransparency = 1
	fadeText.TextTransparency = 1
	local info = TweenInfo.new(0.8)
	TweenService:Create(fade, info, { BackgroundTransparency = 0 }):Play()
	TweenService:Create(fadeTitle, info, { TextTransparency = 0 }):Play()
	TweenService:Create(fadeText, info, { TextTransparency = 0 }):Play()
	task.delay(hold, function()
		local out = TweenInfo.new(1.2)
		TweenService:Create(fade, out, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(fadeTitle, out, { TextTransparency = 1 }):Play()
		TweenService:Create(fadeText, out, { TextTransparency = 1 }):Play()
		task.wait(1.3)
		fade.Visible = false
	end)
end

local function showEnding(data: any)
	ending.Visible = true
	updateDot()
	UiKit.clear(endingCol)
	ending.BackgroundTransparency = 1
	TweenService:Create(ending, TweenInfo.new(2), { BackgroundTransparency = 0 }):Play()
	local title = tostring(data.title)
	-- Silkscreen only for a short title; anything longer reads better in Ubuntu
	if #title <= 16 then
		UiKit.text("display", { Text = title, TextSize = 48, Size = UDim2.new(1, 0, 0, 56), TextColor3 = CARD_TEXT, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 0, Parent = endingCol })
	else
		UiKit.text("heading", { Text = title, TextSize = 32, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, TextColor3 = CARD_TEXT, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 0, Parent = endingCol })
	end
	UiKit.frame({ Name = "Rule", Size = UDim2.fromOffset(160, 1), BackgroundColor3 = C.hudLine, BackgroundTransparency = 0.5, LayoutOrder = 1, Parent = endingCol })
	for i, line in data.lines :: { string } do
		local l = UiKit.text("dialogue", {
			Text = line,
			TextSize = 20,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextColor3 = C.hudText,
			TextTransparency = 1,
			TextXAlignment = Enum.TextXAlignment.Center,
			LayoutOrder = 1 + i,
			Parent = endingCol,
		})
		task.delay(1.5 + i * 2.2, function()
			TweenService:Create(l, TweenInfo.new(1.5), { TextTransparency = 0 }):Play()
		end)
	end
	endingStats.Text = string.format("%s  -  shift length %d:%02d  -  thanks for playing", Config.GAME_TITLE, data.minutes or 0, data.seconds or 0)
	endingStats.TextTransparency = 0
	task.delay(Config.PHASE.endingSeconds - 2, function()
		fadeOut(ending, 1.5)
		task.wait(1.6)
		ending.Visible = false
		updateDot()
	end)
end

---------------------------------------------------------------------------

local function build()
	local playerGui = player:WaitForChild("PlayerGui")
	gui = UiKit.new("ScreenGui", { Name = "Hud", ResetOnSpawn = false, DisplayOrder = 6, IgnoreGuiInset = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = playerGui })

	-- top left: objective, then live threats
	leftCol = column("Left", Vector2.zero, UDim2.fromOffset(EDGE, EDGE), 0.3, 260, 400, gui)
	list(leftCol, SPACE.s)
	objectivePanel = UiKit.panel({ Name = "Objective", Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = leftCol })
	list(objectivePanel, SPACE.xs)
	local head = strip(objectivePanel, 16, 1)
	UiKit.text("title", { Text = "OBJECTIVE", Size = UDim2.fromScale(1, 1), TextWrapped = false, TextColor3 = C.amber, Parent = head })
	clockText = UiKit.text("title", { Text = "", Size = UDim2.fromScale(1, 1), TextWrapped = false, TextColor3 = C.hudDim, TextXAlignment = Enum.TextXAlignment.Right, Parent = head })
	objectiveText = UiKit.text("heading", { Text = "", Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, TextColor3 = C.hudText, LayoutOrder = 2, Parent = objectivePanel })
	local bar = UiKit.frame({ Name = "Erased", Size = UDim2.new(1, 0, 0, 4), BackgroundColor3 = C.charcoal, LayoutOrder = 3, Parent = objectivePanel })
	progressFill = UiKit.frame({ Name = "Fill", Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.amber, Parent = bar })
	local foot = strip(objectivePanel, 16, 4)
	erasedText = UiKit.text("title", { Text = "", Size = UDim2.fromScale(1, 1), TextWrapped = false, TextColor3 = C.hudDim, Parent = foot })
	crewText = UiKit.text("title", { Text = "", Size = UDim2.fromScale(1, 1), TextWrapped = false, TextColor3 = C.hudDim, TextXAlignment = Enum.TextXAlignment.Right, Parent = foot })

	threatList = UiKit.frame({ Name = "Threats", Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 2, Visible = false, Parent = leftCol })
	list(threatList, SPACE.xs)

	-- top right: crew
	rightCol = column("Right", Vector2.new(1, 0), UDim2.new(1, -EDGE, 0, EDGE), 0.22, 220, 300, gui)
	list(rightCol, SPACE.s)
	teamPanel = UiKit.panel({ Name = "Crew", Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Visible = false, Parent = rightCol })
	list(teamPanel, 2)
	UiKit.text("title", { Text = "CREW", Size = UDim2.new(1, 0, 0, 18), TextWrapped = false, TextColor3 = C.amber, LayoutOrder = 0, Parent = teamPanel })

	-- bottom centre: toasts above the carry hint above the controls line;
	-- the interaction prompt card sits between this and the screen centre
	bottomCol = column("Bottom", Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, -EDGE), 0.42, 300, 560, gui)
	list(bottomCol, SPACE.s, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
	toastStack = UiKit.frame({ Name = "Toasts", Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 1, Visible = false, Parent = bottomCol })
	list(toastStack, SPACE.xs)

	carryPlate = UiKit.panel({ Name = "Carry", Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Visible = false, Parent = bottomCol })
	setStroke(carryPlate, C.amber, 0.35)
	list(carryPlate, 2)
	local carryHead = strip(carryPlate, 18, 1)
	list(carryHead, SPACE.s, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center })
	UiKit.text("title", { Text = "CARRYING", Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, TextWrapped = false, TextColor3 = C.amber, LayoutOrder = 1, Parent = carryHead })
	carryItem = UiKit.text("body", { Text = "", Font = UiKit.FONT_BOLD, Size = UDim2.fromScale(0, 1), TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd, TextColor3 = C.hudText, LayoutOrder = 2, Parent = carryHead })
	UiKit.new("UIFlexItem", { FlexMode = Enum.UIFlexMode.Fill, Parent = carryItem })
	carryHow = UiKit.text("caption", { Text = "", Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, TextColor3 = C.hudDim, LayoutOrder = 2, Parent = carryPlate })

	hints = UiKit.frame({ Name = "Controls", Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.XY, BackgroundColor3 = C.hud, BackgroundTransparency = 0.35, LayoutOrder = 3, Parent = bottomCol })
	UiKit.stroke(hints, C.hudLine, 0.7)
	UiKit.padding(hints, SPACE.s, SPACE.xs)
	list(hints, SPACE.l, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center })
	hint(1, "E", "X", "Interact")
	hintDrive = hint(2, "F", "R1", "Dock / stage drive")
	hintDrive.Visible = false
	hint(3, "G", "Y", "Ping")

	-- full-screen layers sit above the desktop and the prompt card
	top = UiKit.new("ScreenGui", { Name = "HudTop", ResetOnSpawn = false, DisplayOrder = 20, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = playerGui })

	dot = UiKit.frame({ Name = "Dot", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(4, 4), BackgroundColor3 = C.hudText, BackgroundTransparency = 0.4, Visible = false, ZIndex = 1, Parent = top })
	UiKit.stroke(dot, C.hud, 0.75)

	downedOverlay = UiKit.frame({ Name = "Downed", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(34, 8, 10), BackgroundTransparency = 0.45, Visible = false, ZIndex = 2, Parent = top })
	local downCard = UiKit.frame({ Name = "Card", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.42), Size = UDim2.fromScale(0.5, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = C.hud, BackgroundTransparency = 0.12, Parent = downedOverlay })
	UiKit.new("UISizeConstraint", { MinSize = Vector2.new(300, 0), MaxSize = Vector2.new(520, math.huge), Parent = downCard })
	UiKit.stroke(downCard, C.bad, 0.1)
	UiKit.padding(downCard, SPACE.l, SPACE.m)
	list(downCard, SPACE.s, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
	scaled(downCard)
	downedTitle = UiKit.text("display", { Text = "CAUGHT", Size = UDim2.new(1, 0, 0, 36), TextWrapped = false, TextColor3 = ALERT, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 1, Parent = downCard })
	downedText = UiKit.text("dialogue", { Text = "", Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, TextColor3 = C.hudText, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 2, Parent = downCard })

	fade = UiKit.frame({ Name = "Fade", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), Visible = false, ZIndex = 10, Parent = top })
	local fadeCol = UiKit.frame({ Name = "Column", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.46), Size = UDim2.fromScale(0.7, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = fade })
	UiKit.new("UISizeConstraint", { MaxSize = Vector2.new(640, math.huge), Parent = fadeCol })
	list(fadeCol, SPACE.s, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
	scaled(fadeCol)
	fadeTitle = UiKit.text("display", { Text = "", Size = UDim2.new(1, 0, 0, 36), TextWrapped = false, TextColor3 = CARD_TEXT, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 1, Parent = fadeCol })
	fadeText = UiKit.text("dialogue", { Text = "", Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, TextColor3 = C.hudDim, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 2, Parent = fadeCol })

	ending = UiKit.frame({ Name = "Ending", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), Visible = false, ZIndex = 20, Parent = top })
	endingCol = UiKit.frame({ Name = "Column", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.45), Size = UDim2.fromScale(0.7, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = ending })
	UiKit.new("UISizeConstraint", { MaxSize = Vector2.new(720, math.huge), Parent = endingCol })
	list(endingCol, SPACE.m, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
	scaled(endingCol)
	endingStats = UiKit.text("caption", { Text = "", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -SPACE.xl), Size = UDim2.new(0.9, 0, 0, 18), TextColor3 = Color3.fromRGB(140, 140, 130), TextXAlignment = Enum.TextXAlignment.Center, Parent = ending })

	-- loading card: one/two pixel words, then a plain sentence
	loading = UiKit.frame({ Name = "Loading", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(8, 9, 11), ZIndex = 30, Parent = top })
	local loadCol = UiKit.frame({ Name = "Column", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.46), Size = UDim2.fromScale(0.8, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = loading })
	UiKit.new("UISizeConstraint", { MaxSize = Vector2.new(720, math.huge), Parent = loadCol })
	list(loadCol, SPACE.s, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
	scaled(loadCol)
	local main, sub = string.match(Config.GAME_TITLE, "^(.-):%s*(.+)$")
	UiKit.text("display", { Text = main or Config.GAME_TITLE, TextSize = 48, Size = UDim2.new(1, 0, 0, 52), TextWrapped = false, TextColor3 = CARD_TEXT, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 1, Parent = loadCol })
	if sub then
		UiKit.text("title", { Text = sub, TextSize = 24, Size = UDim2.new(1, 0, 0, 28), TextWrapped = false, TextColor3 = C.amber, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 2, Parent = loadCol })
	end
	UiKit.frame({ Name = "Rule", Size = UDim2.fromOffset(160, 1), BackgroundColor3 = C.hudLine, BackgroundTransparency = 0.5, LayoutOrder = 3, Parent = loadCol })
	UiKit.text("body", { Text = Dialogue.COMPANY .. ", night operations.", Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, TextColor3 = C.hudDim, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 4, Parent = loadCol })
	UiKit.text("title", { Text = "CLOCKING IN...", Size = UDim2.new(1, 0, 0, 20), TextWrapped = false, TextColor3 = C.hudDim, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 5, Parent = loadCol })

	local camConn: RBXScriptConnection? = nil
	local function hookCamera()
		if camConn then
			camConn:Disconnect()
		end
		local cam = workspace.CurrentCamera
		if cam then
			camConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
		end
		rescale()
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hookCamera)
	hookCamera()
end

function Hud.init()
	build()
	refreshHints()
	State.Changed:Connect(render)
	State.Notified:Connect(function(text, kind)
		Hud.toast(text, kind)
	end)
	State.SessionChanged:Connect(function()
		task.defer(applyMode) -- after the desktop has opened/closed
	end)
	State.Fx:Connect(function(name, data)
		if name == "BossMessage" and not Desktop.isOpen() then
			Hud.toast(data.text, if data.kind == "false" then "bad" else "info", { tag = "PAGER", speaker = data.from, dialogue = true })
		elseif name == "Fragment" and not Desktop.isOpen() then
			local f = Dialogue.FRAGMENTS[data.index]
			if f then
				Hud.toast(f.title .. " was recovered before shredding. Read it in My Files at the workstation.", "info", { tag = "FILE RECOVERED" })
			end
		elseif name == "CheckpointSaved" then
			Hud.toast(sentence(tostring(data.label)) .. ".", "good", { tag = "CHECKPOINT" })
		elseif name == "Restore" then
			showFade("CHECKPOINT", sentence(tostring(data.reason)) .. ". Returning to the last checkpoint.", 2.2)
		elseif name == "TeamCaught" then
			downedTitle.Text = if data.solo then "CAUGHT" else "TEAM CAUGHT"
			downedText.Text = "Returning to the last checkpoint..."
		elseif name == "Ending" then
			showEnding(data)
		elseif name == "Escaped" and data.name == player.DisplayName then
			Hud.toast("You made it outside. Wait for the others.", "good")
		end
	end)
	player:GetAttributeChangedSignal("Downed"):Connect(function()
		local downed = player:GetAttribute("Downed") == true
		downedOverlay.Visible = downed
		if downed then
			downedTitle.Text = "CAUGHT"
			downedText.Text = if #Players:GetPlayers() <= 1 then "Returning to the last checkpoint..." else "Hold on. A teammate can help you up by holding E next to you."
		end
		updateDot()
	end)
	player:GetAttributeChangedSignal("Carrying"):Connect(function()
		if State.snapshot then
			render(State.snapshot)
		end
	end)
	Cursor.Changed:Connect(updateDot)
	local lastMode = inputMode()
	UserInputService.LastInputTypeChanged:Connect(function()
		local mode = inputMode()
		if mode ~= lastMode then
			lastMode = mode
			refreshHints()
		end
	end)
end

function Hud.start()
	-- loading card until the art is baked (or a short timeout)
	local t0 = os.clock()
	while workspace:GetAttribute("ClientArtReady") ~= true and os.clock() - t0 < 25 do
		task.wait(0.2)
	end
	fadeOut(loading, 1.5)
	task.wait(1.6)
	loading.Visible = false
	updateDot()
	-- periodic refresh keeps crew status in sync with attribute changes
	while true do
		task.wait(1)
		if State.snapshot then
			renderTeam(State.snapshot)
		end
		updateDot()
	end
end

return Hud
