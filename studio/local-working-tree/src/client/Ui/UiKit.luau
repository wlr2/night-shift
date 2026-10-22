--!strict
-- Tiny UI toolkit for the workstation desktop and the HUD: cream/grey
-- bevelled windows, charcoal-blue title bars, chunky buttons and one
-- typographic hierarchy for the whole game:
--   PIXEL  Silkscreen    short retro labels, window titles, status, keycaps
--   BODY   Ubuntu        dialogue, instructions, buttons, longer text
--   MONO   Inconsolata   file listings, tables, checksums
-- Props named "Font" that hold a Font object are applied to FontFace.

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local UiKit = {}

UiKit.FAST = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
UiKit.POP = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
UiKit.FADE = TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

local SILKSCREEN = "rbxassetid://12187371840"
local UBUNTU = "rbxasset://fonts/families/Ubuntu.json"
local INCONSOLATA = "rbxasset://fonts/families/Inconsolata.json"

UiKit.FONT = Font.new(UBUNTU, Enum.FontWeight.Regular)
UiKit.FONT_BOLD = Font.new(UBUNTU, Enum.FontWeight.Bold)
UiKit.FONT_MONO = Font.new(INCONSOLATA, Enum.FontWeight.Regular)
UiKit.FONT_PIXEL = Font.new(SILKSCREEN, Enum.FontWeight.Regular)
UiKit.FONT_PIXEL_BOLD = Font.new(SILKSCREEN, Enum.FontWeight.Bold)

UiKit.C = {
	face = Color3.fromRGB(208, 204, 194),
	faceDark = Color3.fromRGB(122, 120, 114),
	faceLight = Color3.fromRGB(242, 240, 234),
	text = Color3.fromRGB(26, 28, 30),
	textDim = Color3.fromRGB(96, 98, 100),
	title1 = Color3.fromRGB(60, 72, 82),
	title2 = Color3.fromRGB(88, 104, 116),
	desktop = Color3.fromRGB(64, 84, 92),
	taskbar = Color3.fromRGB(208, 204, 194),
	start = Color3.fromRGB(208, 204, 194),
	good = Color3.fromRGB(56, 118, 74),
	bad = Color3.fromRGB(156, 56, 50),
	warn = Color3.fromRGB(176, 136, 56),
	info = Color3.fromRGB(62, 88, 118),
	select = Color3.fromRGB(60, 76, 92),
	white = Color3.fromRGB(244, 242, 236),
	field = Color3.fromRGB(246, 244, 236),
	amber = Color3.fromRGB(200, 166, 107),
	cream = Color3.fromRGB(183, 176, 156),
	charcoal = Color3.fromRGB(53, 63, 70),
	hud = Color3.fromRGB(20, 24, 28),
	hudLine = Color3.fromRGB(150, 160, 166),
	hudText = Color3.fromRGB(236, 232, 222),
	hudDim = Color3.fromRGB(168, 176, 182),
}

export type Props = { [string]: any }

function UiKit.new(className: string, props: Props, children: { Instance }?): any
	local inst = Instance.new(className)
	for k, v in props do
		if k == "Parent" then
			continue
		end
		if k == "Font" and typeof(v) == "Font" then
			(inst :: any).FontFace = v
		else
			(inst :: any)[k] = v
		end
	end
	local kids: { Instance } = children or {}
	for _, c in kids do
		c.Parent = inst
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

function UiKit.frame(props: Props): Frame
	local p = table.clone(props)
	p.BorderSizePixel = p.BorderSizePixel or 0
	p.BackgroundColor3 = p.BackgroundColor3 or UiKit.C.face
	return UiKit.new("Frame", p)
end

function UiKit.label(props: Props): TextLabel
	local p = table.clone(props)
	p.BackgroundTransparency = p.BackgroundTransparency or 1
	p.Font = p.Font or UiKit.FONT
	p.TextColor3 = p.TextColor3 or UiKit.C.text
	p.TextSize = p.TextSize or 16
	p.TextXAlignment = p.TextXAlignment or Enum.TextXAlignment.Left
	p.TextWrapped = if p.TextWrapped == nil then true else p.TextWrapped
	p.BorderSizePixel = 0
	return UiKit.new("TextLabel", p)
end

-- 1px outline used by HUD panels, keycaps and prompt cards
function UiKit.stroke(parent: GuiObject, color: Color3?, transparency: number?, thickness: number?): UIStroke
	return UiKit.new("UIStroke", {
		Color = color or UiKit.C.hudLine,
		Transparency = transparency or 0.45,
		Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

function UiKit.padding(parent: GuiObject, x: number, y: number?)
	local py = y or x
	UiKit.new("UIPadding", {
		PaddingLeft = UDim.new(0, x),
		PaddingRight = UDim.new(0, x),
		PaddingTop = UDim.new(0, py),
		PaddingBottom = UDim.new(0, py),
		Parent = parent,
	})
end

-- Square HUD plate: dark translucent, thin outline, consistent padding.
function UiKit.panel(props: Props): Frame
	local p = table.clone(props)
	p.BackgroundColor3 = p.BackgroundColor3 or UiKit.C.hud
	p.BackgroundTransparency = if p.BackgroundTransparency == nil then 0.22 else p.BackgroundTransparency
	local f = UiKit.frame(p)
	UiKit.stroke(f)
	UiKit.padding(f, 10, 8)
	return f
end

-- Small keycap: cream key, charcoal pixel letter, darker base edge.
function UiKit.keycap(parent: Instance, key: string, size: number, zindex: number?): Frame
	local z = zindex or 1
	local cap = UiKit.frame({
		Name = "Key",
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = Color3.fromRGB(228, 222, 204),
		ZIndex = z,
		Parent = parent,
	})
	UiKit.stroke(cap, Color3.fromRGB(70, 78, 84), 0.1)
	UiKit.frame({ Name = "Base", Size = UDim2.new(1, 0, 0, 3), Position = UDim2.new(0, 0, 1, -3), BackgroundColor3 = Color3.fromRGB(150, 144, 126), ZIndex = z + 1, Parent = cap })
	local l = UiKit.label({
		Name = "Letter",
		Text = key,
		Size = UDim2.new(1, 0, 1, -3),
		Font = UiKit.FONT_PIXEL,
		TextColor3 = Color3.fromRGB(40, 46, 52),
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = z + 2,
		Parent = cap,
	})
	UiKit.new("UITextSizeConstraint", { MaxTextSize = 16, MinTextSize = 8, Parent = l })
	UiKit.padding(l, 3, 2)
	return cap
end

-- 3D bevel like classic Windows controls
function UiKit.bevel(f: GuiObject, sunken: boolean?)
	local light = UiKit.frame({ Name = "BevelL", Size = UDim2.new(1, 0, 0, 2), BackgroundColor3 = if sunken then UiKit.C.faceDark else UiKit.C.faceLight, ZIndex = f.ZIndex + 1, Parent = f })
	light.Active = false
	UiKit.frame({ Name = "BevelL2", Size = UDim2.new(0, 2, 1, 0), BackgroundColor3 = if sunken then UiKit.C.faceDark else UiKit.C.faceLight, ZIndex = f.ZIndex + 1, Parent = f })
	UiKit.frame({ Name = "BevelD", Size = UDim2.new(1, 0, 0, 2), Position = UDim2.new(0, 0, 1, -2), BackgroundColor3 = if sunken then UiKit.C.faceLight else UiKit.C.faceDark, ZIndex = f.ZIndex + 1, Parent = f })
	UiKit.frame({ Name = "BevelD2", Size = UDim2.new(0, 2, 1, 0), Position = UDim2.new(1, -2, 0, 0), BackgroundColor3 = if sunken then UiKit.C.faceLight else UiKit.C.faceDark, ZIndex = f.ZIndex + 1, Parent = f })
end

local clickSound: Sound? = nil
function UiKit.click()
	if not clickSound then
		local s = Instance.new("Sound")
		s.SoundId = Config.SOUNDS.click
		s.Volume = 0.25
		s.PlaybackSpeed = 1.6
		s.Parent = SoundService
		clickSound = s
	end
	local s = clickSound :: Sound
	s.PlaybackSpeed = 1.5 + math.random() * 0.2
	s:Play()
end

export type ButtonOpts = {
	text: string,
	size: UDim2,
	position: UDim2?,
	parent: Instance,
	color: Color3?,
	textColor: Color3?,
	textSize: number?,
	font: Font?,
	zindex: number?,
	onClick: (() -> ())?,
	name: string?,
	bevel: boolean?,
}

function UiKit.button(o: ButtonOpts): TextButton
	local b = UiKit.new("TextButton", {
		Name = o.name or "Button",
		Size = o.size,
		Position = o.position or UDim2.new(),
		BackgroundColor3 = o.color or UiKit.C.face,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = o.text,
		TextColor3 = o.textColor or UiKit.C.text,
		TextSize = o.textSize or 16,
		Font = o.font or UiKit.FONT_BOLD,
		TextWrapped = true,
		ZIndex = o.zindex or 1,
		Selectable = true,
		Parent = o.parent,
	}) :: TextButton
	if o.bevel ~= false then
		UiKit.bevel(b)
	end
	local base = b.BackgroundColor3
	b.MouseEnter:Connect(function()
		if b.Active then
			b.BackgroundColor3 = base:Lerp(Color3.new(1, 1, 1), 0.12)
		end
	end)
	b.MouseLeave:Connect(function()
		b.BackgroundColor3 = base
	end)
	b.SelectionGained:Connect(function()
		b.BackgroundColor3 = base:Lerp(UiKit.C.amber, 0.35)
	end)
	b.SelectionLost:Connect(function()
		b.BackgroundColor3 = base
	end)
	if o.onClick then
		local cb = o.onClick
		b.Activated:Connect(function()
			if not b.Active then
				return
			end
			UiKit.click()
			local scale = b:FindFirstChildOfClass("UIScale") or UiKit.new("UIScale", { Parent = b })
			scale.Scale = 0.96
			TweenService:Create(scale, UiKit.POP, { Scale = 1 }):Play()
			cb()
		end)
	end
	return b
end

function UiKit.setEnabled(b: GuiButton, enabled: boolean)
	b.Active = enabled
	b.AutoButtonColor = false
	if b:IsA("TextButton") then
		b.TextTransparency = if enabled then 0 else 0.55
	end
end

-- Classic window: grey body, charcoal-blue title bar with a pixel title, close button.
export type Window = {
	frame: Frame,
	body: Frame,
	title: TextLabel,
	close: TextButton?,
}

function UiKit.window(parent: Instance, title: string, size: UDim2, position: UDim2, zindex: number, onClose: (() -> ())?): Window
	local f = UiKit.frame({ Name = "Window", Size = size, Position = position, ZIndex = zindex, Parent = parent })
	UiKit.bevel(f)
	local bar = UiKit.frame({ Name = "TitleBar", Size = UDim2.new(1, -6, 0, 24), Position = UDim2.fromOffset(3, 3), BackgroundColor3 = UiKit.C.title1, ZIndex = zindex + 1, Parent = f })
	UiKit.new("UIGradient", {
		Color = ColorSequence.new(UiKit.C.title1, UiKit.C.title2),
		Parent = bar,
	})
	local t = UiKit.label({
		Name = "Title",
		Text = title,
		Size = UDim2.new(1, -64, 1, 0),
		Position = UDim2.fromOffset(8, 0),
		TextColor3 = UiKit.C.white,
		Font = UiKit.FONT_PIXEL,
		TextSize = 16,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = zindex + 2,
		Parent = bar,
	})
	local close: TextButton? = nil
	if onClose then
		close = UiKit.button({
			name = "Close",
			text = "X",
			size = UDim2.fromOffset(22, 18),
			position = UDim2.new(1, -25, 0, 3),
			parent = bar,
			zindex = zindex + 3,
			textSize = 16,
			font = UiKit.FONT_PIXEL,
			onClick = onClose,
		})
	end
	local body = UiKit.frame({ Name = "Body", Size = UDim2.new(1, -12, 1, -36), Position = UDim2.fromOffset(6, 30), BackgroundTransparency = 1, ZIndex = zindex + 1, Parent = f })
	return { frame = f, body = body, title = t, close = close }
end

function UiKit.progress(parent: Instance, size: UDim2, position: UDim2, zindex: number): (Frame, Frame)
	local back = UiKit.frame({ Name = "Progress", Size = size, Position = position, BackgroundColor3 = UiKit.C.field, ZIndex = zindex, Parent = parent })
	UiKit.bevel(back, true)
	local fill = UiKit.frame({ Name = "Fill", Size = UDim2.fromScale(0, 1), BackgroundColor3 = UiKit.C.good, ZIndex = zindex + 1, Parent = back })
	return back, fill
end

function UiKit.clear(f: Instance)
	for _, c in f:GetChildren() do
		if not c:IsA("UIBase") then
			c:Destroy()
		end
	end
end

return UiKit
