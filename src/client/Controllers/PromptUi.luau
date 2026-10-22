--!strict
-- Custom interaction prompt. The server still owns the ProximityPrompts
-- (reach, hold time, validation), but every prompt is Style = Custom, so
-- Roblox draws nothing. This draws one card: a keycap, the action ("Collect
-- drive"), the object ("HD-1147"), an amber hold bar and - only when a prompt
-- on another key is in reach too - a smaller second row (F "Dock drive" under
-- E "Sit down"). There is only ever one card, so prompts never overlap.
--
-- Targeting happens here, not in Roblox: among enabled, on-screen prompts in
-- reach, the one nearest the centre of view wins, distance breaks ties, and
-- the current target is sticky so neighbours do not flicker. Every other
-- prompt gets MaxActivationDistance 0 locally, so a key press always fires
-- exactly what the card shows, and the card only draws a prompt once Roblox
-- has shown it (if Roblox declines one, it is skipped for a moment). The
-- real reach travels in the "Reach" attribute; the server re-validates every
-- trigger with its own values.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local UiKit = require(script.Parent.Parent.Ui.UiKit)
local Cursor = require(script.Parent.Parent.Ui.Cursor)
local Desktop = require(script.Parent.Desktop)

local player = Players.LocalPlayer
local C = UiKit.C

local PromptUi = {}

-- targeting
local MAX_ANGLE = 60 -- degrees off the view centre before a prompt is ignored,
local CLOSE = 3.5 -- unless it is this close (studs)
local DIST_WEIGHT = 3 -- cost of one stud of distance, in degrees
local STICKY = 12 -- head start of a prompt already on the card, in degrees
local REACH_IN = 0.5 -- a new target must be this far inside its reach (studs)
local SCREEN_IN = 0.02 -- and this far inside the viewport edges (fraction of the short side)
local GRACE = 0.3 -- seconds an armed prompt may wait for Roblox to show it
local HIDE_GRACE = 0.05 -- ...or to show it again after Roblox hid it while armed
local FLASH = 0.18

-- layout in px at scale 1; scale = viewport height / 1080 in [1, 1.5] like the HUD
local REF_HEIGHT = 1080
local SCALE_MAX = 1.5
local CAP = 28
local CAP_SMALL = 24
local GAP = 10 -- keycap to text
local PAD_X = 10
local PAD_Y = 8
local ROW_GAP = 6
local LINE_ACTION = 20
local LINE_SMALL = 18
local LINE_OBJECT = 17
local ACTION_SIZE = 17
local SMALL_SIZE = 15
local OBJECT_SIZE = UiKit.TYPE.caption.size
local HOLD_H = 3
local MAX_TEXT = 240
-- placement: just under the target, but always below the centre dot and
-- above Hud's bottom column (it keeps clear of PROMPT_Y * height + 92 px)
local BELOW = 22
local DOT_GAP = 26
local SPREAD = 0.16 -- card centre stays within this fraction of the width from the middle
local PROMPT_Y = 0.6
local PROMPT_CLEAR = 88
local EDGE = 16
local FOLLOW = 16 -- smoothing rate (1/s): settles in ~0.2 s

type Info = {
	reach: number,
	shown: boolean, -- Roblox has fired PromptShown and not PromptHidden
	waitSince: number?, -- armed but not (or no longer) shown by Roblox
	waitLimit: number,
	refusals: number, -- consecutive times Roblox would not show it
	refusedUntil: number,
	holdStart: number?,
	flashUntil: number,
	conns: { RBXScriptConnection },
}

type Row = {
	button: TextButton, -- the whole row is the touch target for its prompt
	cap: Frame,
	letter: TextLabel,
	action: TextLabel,
	object: TextLabel,
	holdBack: Frame,
	holdFill: Frame,
	small: boolean,
	prompt: ProximityPrompt?,
}

type Held = { prompt: ProximityPrompt, input: InputObject }

local infos: { [ProximityPrompt]: Info } = {}
-- survives unregistering, so a prompt that leaves and re-enters the
-- workspace never reads back the 0 we wrote
local knownReach: { [ProximityPrompt]: number } = setmetatable({}, { __mode = "k" }) :: any
local costs: { [ProximityPrompt]: number } = {}

local primary: ProximityPrompt? = nil
local second: ProximityPrompt? = nil
local inputMode: Enum.ProximityPromptInputType = Enum.ProximityPromptInputType.Keyboard
local held: Held? = nil

local gui: ScreenGui
local card: Frame
local rows: { Row } = {}
local cardPos: Vector2? = nil

local function worldPosition(p: ProximityPrompt): Vector3?
	local parent = p.Parent
	if parent and parent:IsA("BasePart") then
		return parent.Position
	elseif parent and parent:IsA("Attachment") then
		return parent.WorldPosition
	elseif parent and parent:IsA("Model") then
		return parent:GetPivot().Position
	end
	return nil
end

-- E / F on keyboard, X / R1 on a gamepad, TAP on touch
local function keyText(p: ProximityPrompt): string
	if inputMode == Enum.ProximityPromptInputType.Touch then
		return "TAP"
	elseif inputMode == Enum.ProximityPromptInputType.Gamepad then
		local n = string.gsub(string.gsub(p.GamepadKeyCode.Name, "^Button", ""), "^DPad", "")
		return string.upper(n)
	end
	local n = p.KeyboardKeyCode.Name
	if n == "Space" then
		return "SPC"
	elseif n == "Return" then
		return "RET"
	end
	return string.upper(string.sub(n, 1, 5))
end

local function modeFor(t: Enum.UserInputType): Enum.ProximityPromptInputType?
	if t == Enum.UserInputType.Touch then
		return Enum.ProximityPromptInputType.Touch
	elseif string.sub(t.Name, 1, 7) == "Gamepad" then
		return Enum.ProximityPromptInputType.Gamepad
	elseif t == Enum.UserInputType.Keyboard or string.sub(t.Name, 1, 5) == "Mouse" then
		return Enum.ProximityPromptInputType.Keyboard
	end
	return nil
end

---------------------------------------------------------------------------
-- Registry: every prompt in the workspace, inert until it is targeted

local function endTouch()
	local h = held
	held = nil
	if h then
		h.prompt:InputHoldEnd()
	end
end

local function unregister(p: ProximityPrompt)
	local info = infos[p]
	if not info then
		return
	end
	for _, c in info.conns do
		c:Disconnect()
	end
	infos[p] = nil
	if held and held.prompt == p then
		held = nil
	end
	if primary == p then
		primary = nil
	end
	if second == p then
		second = nil
	end
end

local function register(p: ProximityPrompt)
	if infos[p] or not p:IsDescendantOf(workspace) then
		return
	end
	local attr = p:GetAttribute("Reach")
	local reach = if typeof(attr) == "number" then attr else knownReach[p] or p.MaxActivationDistance
	knownReach[p] = reach
	-- fallback for any prompt not made by Prompts.make: never let Roblox draw it
	if p.Style ~= Enum.ProximityPromptStyle.Custom then
		p.Style = Enum.ProximityPromptStyle.Custom
	end
	local info: Info = {
		reach = reach,
		shown = false,
		waitSince = nil,
		waitLimit = GRACE,
		refusals = 0,
		refusedUntil = 0,
		holdStart = nil,
		flashUntil = 0,
		conns = {},
	}
	infos[p] = info
	p.MaxActivationDistance = 0
	table.insert(
		info.conns,
		p.PromptButtonHoldBegan:Connect(function()
			info.holdStart = os.clock()
		end)
	)
	table.insert(
		info.conns,
		p.PromptButtonHoldEnded:Connect(function()
			info.holdStart = nil
		end)
	)
	table.insert(
		info.conns,
		p:GetAttributeChangedSignal("Reach"):Connect(function()
			local r = p:GetAttribute("Reach")
			if typeof(r) == "number" then
				info.reach = r
				knownReach[p] = r
			end
		end)
	)
	table.insert(
		info.conns,
		p.AncestryChanged:Connect(function()
			if not p:IsDescendantOf(workspace) then
				unregister(p)
			end
		end)
	)
end

---------------------------------------------------------------------------
-- Targeting

local function suppressed(): boolean
	if Desktop.isOpen() or Cursor.isFree() then
		return true
	end
	if player:GetAttribute("Downed") == true or player:GetAttribute("Escaped") == true then
		return true
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid == nil or humanoid.Health <= 0
end

local function rootPosition(): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function armed(p: ProximityPrompt): boolean
	return p == primary or p == second
end

-- Roblox would not show an armed prompt (its own range / view test differs
-- from ours): skip it for a while, backing off if it keeps happening.
local function refuse(info: Info, now: number)
	info.waitSince = nil
	info.refusals += 1
	info.refusedUntil = now + math.min(3, 0.4 * 2 ^ (info.refusals - 1))
end

-- Lower is better: degrees off the view centre plus a distance term.
-- nil when the prompt cannot be the target at all.
local function cost(p: ProximityPrompt, info: Info, cam: Camera, rootPos: Vector3, now: number): number?
	if not p.Enabled or p:GetAttribute("OwnerUserId") == player.UserId then
		return nil -- disabled, or our own "Help up"
	end
	local isHeld = info.holdStart ~= nil or (held ~= nil and held.prompt == p)
	if now < info.refusedUntil and not isHeld then
		return nil
	end
	local pos = worldPosition(p)
	if not pos then
		return nil
	end
	local d = (pos - rootPos).Magnitude
	if d > (if armed(p) then info.reach else info.reach - REACH_IN) then
		return nil
	end
	-- Roblox only shows prompts in view, so only on-screen ones are candidates
	local vp = cam.ViewportSize
	local screen, onScreen = cam:WorldToViewportPoint(pos)
	local m = math.min(vp.X, vp.Y) * SCREEN_IN
	if not onScreen or screen.Z <= 0 or screen.X < m or screen.X > vp.X - m or screen.Y < m or screen.Y > vp.Y - m then
		return nil
	end
	local v = pos - cam.CFrame.Position
	local len = v.Magnitude
	local angle = if len > 0.05 then math.deg(math.acos(math.clamp(cam.CFrame.LookVector:Dot(v / len), -1, 1))) else 0
	if angle > MAX_ANGLE and d > CLOSE then
		return nil
	end
	if isHeld then
		return -math.huge -- never switch away mid-hold
	end
	return angle + d * DIST_WEIGHT
end

local function checkWait(p: ProximityPrompt?, now: number)
	local info = if p then infos[p] else nil
	local since = info and info.waitSince
	if info and since and now - since > info.waitLimit then
		refuse(info, now)
	end
end

-- Picks the primary target and, on a different key, the second row; then
-- arms exactly those two and disarms every other prompt.
local function choose(cam: Camera, now: number)
	checkWait(primary, now)
	checkWait(second, now)
	table.clear(costs)
	local rootPos = rootPosition()
	local newPrimary: ProximityPrompt? = nil
	local newSecond: ProximityPrompt? = nil
	if rootPos and not suppressed() then
		local best = math.huge
		for p, info in infos do
			local c = cost(p, info, cam, rootPos, now)
			if c then
				-- anything already on the card keeps a head start, even when
				-- it trades rows with the other key
				if armed(p) then
					c -= STICKY
				end
				costs[p] = c
				if c < best then
					newPrimary, best = p, c
				end
			end
		end
		if newPrimary then
			local key = newPrimary.KeyboardKeyCode
			local bestSecond = math.huge
			for p, c in costs do
				if p ~= newPrimary and p.KeyboardKeyCode ~= key then
					if c < bestSecond then
						newSecond, bestSecond = p, c
					end
				end
			end
		end
	end
	primary, second = newPrimary, newSecond
	for p, info in infos do
		local on = armed(p)
		local want = if on then info.reach else 0
		if math.abs(p.MaxActivationDistance - want) > 1e-3 then -- stored as float32
			p.MaxActivationDistance = want
			if on and not info.shown then
				info.waitSince, info.waitLimit = now, GRACE
			end
		end
		if not on then
			info.waitSince = nil
		end
	end
end

-- An armed prompt Roblox has not shown yet: the card keeps its last frame
-- for that moment instead of blinking between two targets.
local function waiting(p: ProximityPrompt?): boolean
	local info = if p then infos[p] else nil
	return info ~= nil and info.waitSince ~= nil
end

local function confirmed(p: ProximityPrompt?): boolean
	local info = if p then infos[p] else nil
	return info ~= nil and info.shown
end

---------------------------------------------------------------------------
-- Card

local function makeRow(small: boolean): Row
	local button = UiKit.new("TextButton", {
		Name = if small then "Second" else "Primary",
		Text = "",
		AutoButtonColor = false,
		Selectable = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(200, CAP),
		ZIndex = 2,
		Parent = card,
	}) :: TextButton
	local cap = UiKit.keycap(button, "E", if small then CAP_SMALL else CAP, 3)
	local letter = cap:FindFirstChild("Letter") :: TextLabel
	letter.TextScaled = false -- sized per scale below, so the pixel font stays crisp
	letter.TextSize = UiKit.TYPE.key.size
	local action = UiKit.text("heading", {
		Name = "Action",
		Text = "",
		TextSize = if small then SMALL_SIZE else ACTION_SIZE,
		TextColor3 = C.hudText,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.fromOffset(MAX_TEXT, LINE_ACTION),
		ZIndex = 3,
		Parent = button,
	})
	local object = UiKit.text("caption", {
		Name = "Object",
		Text = "",
		TextColor3 = C.hudDim,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.fromOffset(MAX_TEXT, LINE_OBJECT),
		ZIndex = 3,
		Parent = button,
	})
	local holdBack = UiKit.frame({ Name = "Hold", Size = UDim2.fromOffset(200, HOLD_H), BackgroundColor3 = C.charcoal, ZIndex = 3, Visible = false, Parent = button })
	local holdFill = UiKit.frame({ Name = "Fill", Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.amber, ZIndex = 4, Parent = holdBack })
	local row: Row = {
		button = button,
		cap = cap,
		letter = letter,
		action = action,
		object = object,
		holdBack = holdBack,
		holdFill = holdFill,
		small = small,
		prompt = nil,
	}
	-- touch (or a free mouse) holds the row's own prompt for as long as the
	-- finger stays down; release is caught globally in case it slides off
	button.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t ~= Enum.UserInputType.Touch and t ~= Enum.UserInputType.MouseButton1 then
			return
		end
		local p = row.prompt
		if p and not held and card.Visible then
			held = { prompt = p, input = input }
			p:InputHoldBegin()
		end
	end)
	button.InputEnded:Connect(function(input)
		local h = held
		if h and h.prompt == row.prompt and input.UserInputType == h.input.UserInputType then
			endTouch()
		end
	end)
	return row
end

local function build()
	gui = UiKit.new("ScreenGui", {
		Name = "Prompts",
		ResetOnSpawn = false,
		DisplayOrder = 7,
		IgnoreGuiInset = true,
		ScreenInsets = Enum.ScreenInsets.None,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
	card = UiKit.frame({
		Name = "Card",
		BackgroundColor3 = C.hud,
		BackgroundTransparency = 0.2,
		Size = UDim2.fromOffset(220, 50),
		Visible = false,
		ZIndex = 1,
		Parent = gui,
	})
	UiKit.stroke(card, C.hudLine, 0.45)
	rows[1] = makeRow(false)
	rows[2] = makeRow(true)
end

local function px(v: number, s: number): number
	return math.floor(v * s + 0.5)
end

-- math.clamp, but never throws when the range collapses (tiny viewports)
local function clamp(v: number, lo: number, hi: number): number
	if lo > hi then
		return (lo + hi) / 2
	end
	return math.clamp(v, lo, hi)
end

-- Lays out one row for prompt p; returns its content width and height.
local function fillRow(row: Row, p: ProximityPrompt, s: number, now: number): (number, number)
	row.prompt = p
	local info = infos[p]
	local key = keyText(p)
	if row.letter.Text ~= key then
		row.letter.Text = key
	end
	row.letter.TextSize = if s >= 1.3 then 24 else UiKit.TYPE.key.size -- Silkscreen stays on its 8 px grid
	local capH = px(if row.small then CAP_SMALL else CAP, s)
	local capW = math.max(capH, math.ceil(row.letter.TextBounds.X) + px(12, s))
	local flash = info ~= nil and now < info.flashUntil
	row.cap.BackgroundColor3 = if flash then C.amber else Color3.fromRGB(228, 222, 204)

	local hasObject = p.ObjectText ~= ""
	if row.action.Text ~= p.ActionText then
		row.action.Text = p.ActionText
	end
	if row.object.Text ~= p.ObjectText then
		row.object.Text = p.ObjectText
	end
	row.object.Visible = hasObject
	row.action.TextSize = px(if row.small then SMALL_SIZE else ACTION_SIZE, s)
	row.object.TextSize = px(OBJECT_SIZE, s)
	local lineA = px(if row.small then LINE_SMALL else LINE_ACTION, s)
	local lineO = px(LINE_OBJECT, s)
	local textH = if hasObject then lineA + lineO else lineA
	local rowH = math.max(capH, textH)
	local maxText = px(MAX_TEXT, s)
	-- labels stay maxText wide (truncating past it); the card hugs the text
	local textW = math.min(maxText, math.ceil(math.max(row.action.TextBounds.X, if hasObject then row.object.TextBounds.X else 0)))
	local textX = capW + px(GAP, s)
	local textY = math.floor((rowH - textH) / 2)
	row.cap.Size = UDim2.fromOffset(capW, capH)
	row.cap.Position = UDim2.fromOffset(0, math.floor((rowH - capH) / 2))
	row.action.Size = UDim2.fromOffset(maxText, lineA)
	row.action.Position = UDim2.fromOffset(textX, textY)
	row.object.Size = UDim2.fromOffset(maxText, lineO)
	row.object.Position = UDim2.fromOffset(textX, textY + lineA)

	local height = rowH
	local start = info and info.holdStart
	if start and p.HoldDuration > 0 then
		local gap = px(5, s)
		row.holdBack.Visible = true
		row.holdBack.Position = UDim2.fromOffset(0, rowH + gap)
		row.holdFill.Size = UDim2.fromScale(math.clamp((now - start) / p.HoldDuration, 0, 1), 1)
		height += gap + px(HOLD_H, s)
	else
		row.holdBack.Visible = false
	end
	return textX + textW, height
end

local function hide()
	card.Visible = false
	cardPos = nil
	rows[1].prompt = nil
	rows[2].prompt = nil
	if held then
		endTouch()
	end
end

local function step(dt: number)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local now = os.clock()
	choose(cam, now)
	if card.Visible and (waiting(primary) or waiting(second)) then
		return
	end
	local a: ProximityPrompt? = if confirmed(primary) then primary else nil
	local b: ProximityPrompt? = if confirmed(second) then second else nil
	if not a then
		a, b = b, nil
	end
	local anchor = if a then worldPosition(a) else nil
	if not a or not anchor then
		hide()
		return
	end
	if held and held.prompt ~= a and held.prompt ~= b then
		endTouch()
	end

	local vp = cam.ViewportSize
	local s = math.clamp(vp.Y / REF_HEIGHT, 1, SCALE_MAX)
	local padX, padY = px(PAD_X, s), px(PAD_Y, s)
	local r1, r2 = rows[1], rows[2]
	local w1, h1 = fillRow(r1, a, s, now)
	local inner, y = w1, padY + h1
	if b then
		local w2, h2 = fillRow(r2, b, s, now)
		inner = math.max(w1, w2)
		r2.button.Visible = true
		r2.button.Position = UDim2.fromOffset(padX, y + px(ROW_GAP, s))
		r2.button.Size = UDim2.fromOffset(inner, h2)
		y += px(ROW_GAP, s) + h2
	else
		r2.button.Visible = false
		r2.prompt = nil
	end
	r1.button.Position = UDim2.fromOffset(padX, padY)
	r1.button.Size = UDim2.fromOffset(inner, h1)
	local holdH = math.max(2, px(HOLD_H, s))
	r1.holdBack.Size = UDim2.fromOffset(inner, holdH)
	r2.holdBack.Size = UDim2.fromOffset(inner, holdH)
	local w, h = inner + padX * 2, y + padY
	card.Size = UDim2.fromOffset(w, h)

	-- just under the target, pulled toward the middle, below the centre dot
	-- and above the HUD's bottom column; on screen even when the target is not
	local cx, cy = vp.X / 2, vp.Y / 2
	local tx, ty = cx, cy
	local screen, onScreen = cam:WorldToViewportPoint(anchor)
	if onScreen and screen.Z > 0 then
		tx = screen.X + a.UIOffset.X * s
		ty = screen.Y + a.UIOffset.Y * s + BELOW * s
	end
	local spread = vp.X * SPREAD
	tx = clamp(tx, math.max(cx - spread, EDGE + w / 2), math.min(cx + spread, vp.X - EDGE - w / 2))
	local top = cy + DOT_GAP * s
	ty = clamp(ty, top, math.max(top, vp.Y * PROMPT_Y + PROMPT_CLEAR - h))
	local goal = Vector2.new(tx - w / 2, ty)
	local last = cardPos
	local pos = if last and card.Visible then last:Lerp(goal, 1 - math.exp(-FOLLOW * dt)) else goal
	cardPos = pos
	card.Position = UDim2.fromOffset(math.floor(pos.X + 0.5), math.floor(pos.Y + 0.5))
	card.Visible = true
end

function PromptUi.init()
	build()
	inputMode = modeFor(UserInputService:GetLastInputType())
		or if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
			then Enum.ProximityPromptInputType.Touch
			else Enum.ProximityPromptInputType.Keyboard

	for _, d in workspace:GetDescendants() do
		if d:IsA("ProximityPrompt") then
			register(d)
		end
	end
	workspace.DescendantAdded:Connect(function(d)
		if d:IsA("ProximityPrompt") then
			register(d)
		end
	end)

	ProximityPromptService.PromptShown:Connect(function(prompt, input)
		register(prompt)
		local info = infos[prompt]
		if info then
			info.shown = true
			info.waitSince = nil
			info.refusals = 0
			info.refusedUntil = 0
		end
		inputMode = input
	end)
	ProximityPromptService.PromptHidden:Connect(function(prompt)
		local info = infos[prompt]
		if info then
			info.shown = false
			info.holdStart = nil
			-- hidden by Roblox while we still want it: give it a moment to
			-- come back (property changes can re-show it), then skip it
			if armed(prompt) and prompt.Enabled and prompt.MaxActivationDistance > 0 then
				info.waitSince, info.waitLimit = os.clock(), HIDE_GRACE
			end
		end
		if held and held.prompt == prompt then
			endTouch()
		end
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		local info = infos[prompt]
		if info then
			info.flashUntil = os.clock() + FLASH
		end
	end)

	UserInputService.LastInputTypeChanged:Connect(function(t)
		local mode = modeFor(t)
		if mode then
			inputMode = mode
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		local h = held
		if h and (input == h.input or (input.UserInputType == Enum.UserInputType.MouseButton1 and h.input.UserInputType == Enum.UserInputType.MouseButton1)) then
			endTouch()
		end
	end)

	RunService.RenderStepped:Connect(step)
end

return PromptUi
