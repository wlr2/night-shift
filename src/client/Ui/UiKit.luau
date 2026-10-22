--!strict
-- Tiny UI toolkit for the early-2000s desktop: grey bevelled windows, blue
-- title bars, chunky buttons with pressed/hover/disabled states, and one
-- animation vocabulary for the whole UI.

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local UiKit = {}

UiKit.FAST = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
UiKit.POP = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
UiKit.FADE = TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

UiKit.C = {
	face = Color3.fromRGB(212, 208, 200),
	faceDark = Color3.fromRGB(128, 128, 128),
	faceLight = Color3.fromRGB(255, 255, 255),
	text = Color3.fromRGB(16, 16, 16),
	title1 = Color3.fromRGB(0, 70, 200),
	title2 = Color3.fromRGB(70, 150, 255),
	desktop = Color3.fromRGB(0, 96, 104),
	taskbar = Color3.fromRGB(36, 84, 196),
	start = Color3.fromRGB(60, 150, 60),
	good = Color3.fromRGB(40, 140, 60),
	bad = Color3.fromRGB(190, 40, 40),
	warn = Color3.fromRGB(220, 160, 30),
	info = Color3.fromRGB(40, 80, 160),
	select = Color3.fromRGB(10, 36, 106),
	white = Color3.fromRGB(255, 255, 255),
	field = Color3.fromRGB(255, 255, 255),
}

UiKit.FONT = Enum.Font.Arial
UiKit.FONT_BOLD = Enum.Font.ArialBold
UiKit.FONT_MONO = Enum.Font.Code

export type Props = { [string]: any }

function UiKit.new(className: string, props: Props, children: { Instance }?): any
	local inst = Instance.new(className)
	for k, v in props do
		if k ~= "Parent" then
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
	font: Enum.Font?,
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
			b.BackgroundColor3 = base:Lerp(Color3.new(1, 1, 1), 0.15)
		end
	end)
	b.MouseLeave:Connect(function()
		b.BackgroundColor3 = base
	end)
	b.SelectionGained:Connect(function()
		b.BackgroundColor3 = base:Lerp(Color3.new(1, 1, 0.6), 0.3)
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
			scale.Scale = 0.94
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

-- Classic window: grey body, blue gradient title bar, close button.
export type Window = {
	frame: Frame,
	body: Frame,
	title: TextLabel,
	close: TextButton?,
}

function UiKit.window(parent: Instance, title: string, size: UDim2, position: UDim2, zindex: number, onClose: (() -> ())?): Window
	local f = UiKit.frame({ Name = "Window", Size = size, Position = position, ZIndex = zindex, Parent = parent })
	UiKit.bevel(f)
	local bar = UiKit.frame({ Name = "TitleBar", Size = UDim2.new(1, -6, 0, 26), Position = UDim2.fromOffset(3, 3), BackgroundColor3 = UiKit.C.title1, ZIndex = zindex + 1, Parent = f })
	UiKit.new("UIGradient", {
		Color = ColorSequence.new(UiKit.C.title1, UiKit.C.title2),
		Parent = bar,
	})
	local t = UiKit.label({
		Name = "Title",
		Text = title,
		Size = UDim2.new(1, -70, 1, 0),
		Position = UDim2.fromOffset(8, 0),
		TextColor3 = UiKit.C.white,
		Font = UiKit.FONT_BOLD,
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
			size = UDim2.fromOffset(24, 20),
			position = UDim2.new(1, -27, 0, 3),
			parent = bar,
			zindex = zindex + 3,
			textSize = 14,
			onClick = onClose,
		})
	end
	local body = UiKit.frame({ Name = "Body", Size = UDim2.new(1, -12, 1, -38), Position = UDim2.fromOffset(6, 32), BackgroundTransparency = 1, ZIndex = zindex + 1, Parent = f })
	return { frame = f, body = body, title = t, close = close }
end

function UiKit.progress(parent: Instance, size: UDim2, position: UDim2, zindex: number): (Frame, Frame)
	local back = UiKit.frame({ Name = "Progress", Size = size, Position = position, BackgroundColor3 = UiKit.C.field, ZIndex = zindex, Parent = parent })
	UiKit.bevel(back, true)
	local fill = UiKit.frame({ Name = "Fill", Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.fromRGB(40, 170, 60), ZIndex = zindex + 1, Parent = back })
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
