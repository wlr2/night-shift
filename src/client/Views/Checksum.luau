--!strict
-- CHECKSUM MATCHING view: the TARGET readout, verified count and symbol
-- legend on the left, the record list on the right. Symbols are text glyphs
-- with names, never colour alone. Clicking a record submits it.

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local UiKit = require(script.Parent.Parent.Ui.UiKit)
local C = UiKit.C
local S = UiKit.SPACE
local DIM = UiKit.C.textDim -- secondary text, 5:1 on the face

local SCREEN = Color3.fromRGB(30, 36, 40) -- dark readout well
local PHOSPHOR = Color3.fromRGB(170, 214, 176) -- soft green, not neon
local LEFT_W = 196
local PATTERN_X = 196 -- record row: pattern well starts here
local LEGEND = { "#  hash", "@  at", "%  percent", "&  and", "+  plus", "=  equals", "*  star", "?  query" }

local View = {}

-- Gamepad: every update rebuilds the view, so focus moves to the control
-- that replaces the one that had it.
local function focusName(root: Instance): string?
	local sel = GuiService.SelectedObject
	return if sel and sel:IsDescendantOf(root) then sel.Name else nil
end

local function refocus(root: Instance, name: string?, first: string?)
	local b = if name then root:FindFirstChild(name, true) else nil
	-- a stage change clears the area and drops focus: a pad user gets `first`
	if not b and first and GuiService.SelectedObject == nil and string.sub(UserInputService:GetLastInputType().Name, 1, 7) == "Gamepad" then
		b = root:FindFirstChild(first, true)
	end
	if b and b:IsA("GuiObject") then
		GuiService.SelectedObject = b
	end
end

-- Hint: an amber edge inside the control plus a HINT tag, never colour alone.
local function hintMark(b: GuiObject, tagPos: UDim2, z: number)
	local edge = UiKit.frame({ Name = "HintEdge", Size = UDim2.new(1, -4, 1, -4), Position = UDim2.fromOffset(2, 2), BackgroundTransparency = 1, ZIndex = z, Parent = b })
	UiKit.stroke(edge, C.warn, 0, 2)
	UiKit.text("title", {
		Name = "HintTag",
		Text = "HINT",
		Size = UDim2.fromOffset(48, 18),
		Position = tagPos,
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundTransparency = 0,
		BackgroundColor3 = C.amber,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = false,
		ZIndex = z,
		Parent = b,
	})
end

function View.render(root: Frame, v: { [string]: any }, api: { act: (string, any, any) -> () }, z: number)
	local focus = focusName(root)
	UiKit.clear(root)
	local w = if root.Size.X.Offset > 0 then root.Size.X.Offset else 620
	local h = if root.Size.Y.Offset > 0 then root.Size.Y.Offset else 250

	-- target readout
	UiKit.text("title", { Text = "TARGET", Size = UDim2.fromOffset(LEFT_W, 18), TextWrapped = false, ZIndex = z, Parent = root })
	local screen = UiKit.frame({ Name = "Target", Size = UDim2.fromOffset(LEFT_W, 64), Position = UDim2.fromOffset(0, 20), BackgroundColor3 = SCREEN, ZIndex = z, Parent = root })
	UiKit.bevel(screen, true)
	UiKit.text("mono", {
		Text = v.target,
		TextSize = 28,
		Size = UDim2.fromScale(1, 1),
		TextColor3 = PHOSPHOR,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = false,
		ZIndex = z + 2,
		Parent = screen,
	})

	-- verified counter: the number plus filled / hollow pips
	UiKit.text("title", { Text = "VERIFIED", Size = UDim2.fromOffset(120, 18), Position = UDim2.fromOffset(0, 92), TextWrapped = false, ZIndex = z, Parent = root })
	UiKit.text("mono", {
		Text = string.format("%d / %d", v.matched, v.need),
		Size = UDim2.fromOffset(72, 18),
		Position = UDim2.fromOffset(LEFT_W - 72, 92),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextWrapped = false,
		ZIndex = z,
		Parent = root,
	})
	local need = math.max(1, v.need)
	local pw = math.floor((LEFT_W - (need - 1) * S.xs) / need)
	for i = 1, need do
		local done = i <= v.matched
		local pip = UiKit.frame({ Size = UDim2.fromOffset(pw, 12), Position = UDim2.fromOffset((i - 1) * (pw + S.xs), 114), BackgroundColor3 = if done then C.good else C.field, ZIndex = z, Parent = root })
		UiKit.bevel(pip, not done)
	end

	-- symbol legend, so every glyph has a spoken name
	local legend = UiKit.frame({ Name = "Legend", Size = UDim2.fromOffset(LEFT_W, h - 136), Position = UDim2.fromOffset(0, 136), BackgroundColor3 = C.field, ZIndex = z, Parent = root })
	UiKit.bevel(legend, true)
	UiKit.text("title", { Text = "SYMBOLS", Size = UDim2.new(1, -2 * S.s, 0, 18), Position = UDim2.fromOffset(S.s, S.s), TextColor3 = DIM, TextWrapped = false, ZIndex = z + 2, Parent = legend })
	for i, entry in LEGEND do
		UiKit.text("mono", {
			Text = entry,
			TextSize = 14,
			Size = UDim2.fromOffset(88, 18),
			Position = UDim2.fromOffset(S.s + ((i - 1) // 4) * 92, 30 + ((i - 1) % 4) * 19),
			TextWrapped = false,
			ZIndex = z + 2,
			Parent = legend,
		})
	end

	-- record list: name in mono, pattern in a sunken well
	local lx = LEFT_W + S.m
	local lw = w - lx
	UiKit.text("title", { Text = "RECORDS", Size = UDim2.fromOffset(lw, 18), Position = UDim2.fromOffset(lx, 0), TextWrapped = false, ZIndex = z, Parent = root })
	local n = math.max(1, #v.records)
	local rowH = math.min(44, math.floor((h - 20 - (n - 1) * S.xs) / n))
	for i, r in v.records do
		local hinted = v.highlight == r.id
		local b = UiKit.button({
			name = "Record" .. tostring(r.id),
			text = "",
			size = UDim2.fromOffset(lw, rowH),
			position = UDim2.fromOffset(lx, 20 + (i - 1) * (rowH + S.xs)),
			parent = root,
			zindex = z,
			onClick = function()
				api.act("match", r.id, nil)
			end,
		})
		UiKit.text("mono", {
			Text = r.name,
			TextSize = 15,
			Size = UDim2.new(0, PATTERN_X - S.m - S.s, 1, 0),
			Position = UDim2.fromOffset(S.m, 0),
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = z + 2,
			Parent = b,
		})
		local tagW = if hinted then 48 + S.s else 0
		local well = UiKit.frame({ Name = "Pattern", Size = UDim2.new(1, -(PATTERN_X + S.s + tagW), 1, -10), Position = UDim2.fromOffset(PATTERN_X, 5), BackgroundColor3 = C.field, ZIndex = z + 2, Parent = b })
		UiKit.bevel(well, true)
		UiKit.text("mono", {
			Text = r.pattern,
			TextSize = 20,
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextWrapped = false,
			ZIndex = z + 4,
			Parent = well,
		})
		if hinted then
			hintMark(b, UDim2.new(1, -(48 + S.s), 0.5, 0), z + 4)
		end
	end
	refocus(root, focus, "Record1")
end

return View
