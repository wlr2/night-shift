--!strict
-- Custom proximity prompt presentation. The server still uses ProximityPrompts
-- (distance, hold time, validation); their Style is Custom, so nothing is
-- drawn by Roblox. This draws exactly one card: a keycap, the action label
-- ("Collect drive"), the object ("HD-1147"), a hold bar, and - only when a
-- second prompt on a different key is in reach - a smaller second row.
-- Cards never overlap because there is only ever one.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local UiKit = require(script.Parent.Parent.Ui.UiKit)
local Desktop = require(script.Parent.Desktop)

local player = Players.LocalPlayer

local PromptUi = {}

type Shown = { input: Enum.ProximityPromptInputType, holdStart: number? }
type Row = { frame: Frame, cap: Frame, letter: TextLabel, action: TextLabel, object: TextLabel }

local shown: { [ProximityPrompt]: Shown } = {}
local gui: ScreenGui
local card: TextButton
local rows: { Row } = {}
local holdBack: Frame
local holdFill: Frame
local current: ProximityPrompt? = nil
local flashUntil = 0
local touchHeld: ProximityPrompt? = nil

local CAP = 28
local ROW_H = 34
local PAD_X = 10
local PAD_Y = 8

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

local function keyText(p: ProximityPrompt, input: Enum.ProximityPromptInputType): string
	if input == Enum.ProximityPromptInputType.Gamepad then
		return (string.gsub(p.GamepadKeyCode.Name, "^Button", ""))
	elseif input == Enum.ProximityPromptInputType.Touch then
		return "TAP"
	end
	local n = p.KeyboardKeyCode.Name
	if n == "Space" then
		return "SPC"
	elseif n == "Return" then
		return "RET"
	end
	return n
end

local function makeRow(z: number, small: boolean): Row
	local frame = UiKit.frame({ Name = "Row", BackgroundTransparency = 1, Size = UDim2.fromOffset(200, ROW_H), ZIndex = z, Parent = card })
	local cap = UiKit.keycap(frame, "E", CAP, z + 1)
	cap.Position = UDim2.fromOffset(0, (ROW_H - CAP) / 2)
	local letter = cap:FindFirstChild("Letter") :: TextLabel
	local action = UiKit.label({
		Name = "Action",
		Text = "",
		Size = UDim2.fromOffset(200, 20),
		Position = UDim2.fromOffset(CAP + 10, 1),
		Font = UiKit.FONT_BOLD,
		TextSize = if small then 15 else 17,
		TextColor3 = UiKit.C.hudText,
		TextWrapped = false,
		ZIndex = z + 1,
		Parent = frame,
	})
	local object = UiKit.label({
		Name = "Object",
		Text = "",
		Size = UDim2.fromOffset(200, 14),
		Position = UDim2.fromOffset(CAP + 10, 20),
		Font = UiKit.FONT,
		TextSize = 13,
		TextColor3 = UiKit.C.hudDim,
		TextWrapped = false,
		ZIndex = z + 1,
		Parent = frame,
	})
	return { frame = frame, cap = cap, letter = letter, action = action, object = object }
end

local function build()
	gui = UiKit.new("ScreenGui", { Name = "Prompts", ResetOnSpawn = false, DisplayOrder = 7, IgnoreGuiInset = true, Parent = player:WaitForChild("PlayerGui") })
	card = UiKit.new("TextButton", {
		Name = "Card",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = UiKit.C.hud,
		BackgroundTransparency = 0.18,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(220, 50),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.6),
		Visible = false,
		ZIndex = 2,
		Parent = gui,
	}) :: TextButton
	UiKit.stroke(card, UiKit.C.hudLine, 0.4)
	rows[1] = makeRow(3, false)
	rows[2] = makeRow(3, true)
	holdBack = UiKit.frame({ Name = "Hold", Size = UDim2.fromOffset(200, 3), BackgroundColor3 = Color3.fromRGB(60, 68, 74), ZIndex = 3, Visible = false, Parent = card })
	holdFill = UiKit.frame({ Name = "Fill", Size = UDim2.fromScale(0, 1), BackgroundColor3 = UiKit.C.amber, ZIndex = 4, Parent = holdBack })

	-- touch / click on the card triggers the primary prompt
	card.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			local p = current
			if p then
				touchHeld = p
				p:InputHoldBegin()
			end
		end
	end)
	card.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			local p = touchHeld
			touchHeld = nil
			if p then
				p:InputHoldEnd()
			end
		end
	end)
end

local function track(prompt: ProximityPrompt, input: Enum.ProximityPromptInputType)
	if shown[prompt] then
		shown[prompt].input = input
		return
	end
	local entry: Shown = { input = input, holdStart = nil }
	shown[prompt] = entry
	prompt.PromptButtonHoldBegan:Connect(function()
		entry.holdStart = os.clock()
	end)
	prompt.PromptButtonHoldEnded:Connect(function()
		entry.holdStart = nil
	end)
end

-- nearest enabled prompt wins; the previous one keeps a small advantage so
-- the card does not flip between two objects at equal distance
local function pick(): (ProximityPrompt?, ProximityPrompt?, Vector3?)
	local cam = workspace.CurrentCamera
	local origin = cam.CFrame.Position
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		origin = root.Position
	end
	local best: ProximityPrompt? = nil
	local bestD = math.huge
	local bestPos: Vector3? = nil
	local candidates: { { p: ProximityPrompt, d: number, pos: Vector3 } } = {}
	for p in shown do
		if not p.Enabled or not p.Parent then
			continue
		end
		local pos = worldPosition(p)
		if not pos then
			continue
		end
		local d = (pos - origin).Magnitude
		if p == current then
			d -= 1.0
		end
		table.insert(candidates, { p = p, d = d, pos = pos })
		if d < bestD then
			best, bestD, bestPos = p, d, pos
		end
	end
	local second: ProximityPrompt? = nil
	if best then
		local secondD = math.huge
		for _, c in candidates do
			if c.p ~= best and c.p.KeyboardKeyCode ~= best.KeyboardKeyCode and c.d < secondD then
				second, secondD = c.p, c.d
			end
		end
	end
	return best, second, bestPos
end

local function fillRow(row: Row, p: ProximityPrompt, input: Enum.ProximityPromptInputType, flash: boolean): number
	row.letter.Text = keyText(p, input)
	row.action.Text = p.ActionText
	row.object.Text = p.ObjectText
	row.object.Visible = p.ObjectText ~= ""
	row.action.Position = if p.ObjectText ~= "" then UDim2.fromOffset(CAP + 10, 1) else UDim2.fromOffset(CAP + 10, (ROW_H - 20) / 2)
	row.cap.BackgroundColor3 = if flash then UiKit.C.amber else Color3.fromRGB(228, 222, 204)
	local w = math.max(row.action.TextBounds.X, if p.ObjectText ~= "" then row.object.TextBounds.X else 0)
	row.action.Size = UDim2.fromOffset(w + 4, 20)
	row.object.Size = UDim2.fromOffset(w + 4, 14)
	return CAP + 10 + w + 4
end

local function update()
	local primary, second, pos = pick()
	if not primary or not pos or Desktop.isOpen() then
		current = nil
		card.Visible = false
		return
	end
	current = primary
	local entry = shown[primary]
	local input = if entry then entry.input else Enum.ProximityPromptInputType.Keyboard
	local flash = os.clock() < flashUntil
	local width = fillRow(rows[1], primary, input, flash)
	rows[1].frame.Position = UDim2.fromOffset(PAD_X, PAD_Y)
	local height = PAD_Y + ROW_H
	if second then
		local e2 = shown[second]
		local w2 = fillRow(rows[2], second, if e2 then e2.input else input, false)
		width = math.max(width, w2)
		rows[2].frame.Visible = true
		rows[2].frame.Position = UDim2.fromOffset(PAD_X, height + 2)
		height += ROW_H + 2
	else
		rows[2].frame.Visible = false
	end
	-- hold bar under the primary row while a hold prompt is being held
	local holding = entry and entry.holdStart and primary.HoldDuration > 0
	if holding and entry and entry.holdStart then
		local t = math.clamp((os.clock() - entry.holdStart) / primary.HoldDuration, 0, 1)
		holdBack.Visible = true
		holdBack.Position = UDim2.fromOffset(PAD_X, height + 2)
		holdBack.Size = UDim2.fromOffset(width, 3)
		holdFill.Size = UDim2.fromScale(t, 1)
		height += 5
	else
		holdBack.Visible = false
	end
	for _, r in rows do
		r.frame.Size = UDim2.fromOffset(width, ROW_H)
	end
	card.Size = UDim2.fromOffset(width + PAD_X * 2, height + PAD_Y)

	-- anchor just below the object on screen, clamped so it never leaves the view
	local cam = workspace.CurrentCamera
	local offset = primary.UIOffset
	local screenPos, onScreen = cam:WorldToViewportPoint(pos)
	local vp = cam.ViewportSize
	local target: UDim2
	if onScreen and screenPos.Z > 0 then
		local x = math.clamp(screenPos.X + offset.X, 20 + card.AbsoluteSize.X / 2, vp.X - 20 - card.AbsoluteSize.X / 2)
		local y = math.clamp(screenPos.Y + offset.Y + 28, 60, vp.Y - 130 - card.AbsoluteSize.Y)
		target = UDim2.fromOffset(x, y)
	else
		target = UDim2.fromOffset(vp.X / 2, vp.Y - 150 - card.AbsoluteSize.Y)
	end
	if not card.Visible then
		card.Position = target
		card.Visible = true
	else
		card.Position = card.Position:Lerp(target, 0.4)
	end
end

function PromptUi.init()
	build()
	ProximityPromptService.PromptShown:Connect(function(prompt, input)
		if prompt:GetAttribute("OwnerUserId") == player.UserId then
			return -- our own "Help up" prompt
		end
		track(prompt, input)
	end)
	ProximityPromptService.PromptHidden:Connect(function(prompt)
		shown[prompt] = nil
		if touchHeld == prompt then
			touchHeld = nil
		end
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		if prompt == current then
			flashUntil = os.clock() + 0.18
		end
	end)
	-- gamepad / keyboard switches re-label the keycap
	UserInputService.LastInputTypeChanged:Connect(function(t)
		local mapped: Enum.ProximityPromptInputType? = nil
		if t == Enum.UserInputType.Gamepad1 then
			mapped = Enum.ProximityPromptInputType.Gamepad
		elseif t == Enum.UserInputType.Keyboard or t == Enum.UserInputType.MouseMovement then
			mapped = Enum.ProximityPromptInputType.Keyboard
		elseif t == Enum.UserInputType.Touch then
			mapped = Enum.ProximityPromptInputType.Touch
		end
		if mapped then
			for _, e in shown do
				e.input = mapped
			end
		end
	end)
	RunService.RenderStepped:Connect(update)
end

return PromptUi
