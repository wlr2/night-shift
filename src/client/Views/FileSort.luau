--!strict
-- FILE SORTING view: numbered rules on the left, a details-view file list
-- and the PURGE / KEEP bins under it. Click a file, then a bin (no dragging).

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local UiKit = require(script.Parent.Parent.Ui.UiKit)
local C = UiKit.C
local S = UiKit.SPACE
local DIM = UiKit.C.textDim -- secondary text, 5:1 on the face

local RULES_W = 188
local BIN_H = 44
local HEAD_H = 20

type Col = { title: string, x: number, w: number }
-- details-view columns, x relative to the row
local MARK: Col = { title = "", x = 4, w = 12 }
local COLS: { Col } = {
	{ title = "NAME", x = 18, w = 150 },
	{ title = "YEAR", x = 172, w = 40 },
	{ title = "DEPT", x = 216, w = 92 },
	{ title = "TAG", x = 312, w = 104 },
}

local View = {}
local selected: number? = nil
local lastKey = ""

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

-- Rule text with its leading verb (PURGE / KEEP / EXCEPTION:) in bold.
local function richRule(i: number, text: string): string
	local safe = string.gsub(text, "&", "&amp;")
	safe = string.gsub(safe, "<", "&lt;")
	safe = string.gsub(safe, ">", "&gt;")
	safe = string.gsub(safe, "^(%u+:?)", "<b>%1</b>")
	return string.format("<b>%d.</b> %s", i, safe)
end

local function rulesPanel(root: Frame, rules: { string }, h: number, z: number)
	local panel = UiKit.frame({ Name = "Rules", Size = UDim2.fromOffset(RULES_W, h), BackgroundColor3 = C.field, ZIndex = z, Parent = root })
	UiKit.bevel(panel, true)
	UiKit.text("title", { Text = "RULES", Size = UDim2.new(1, -2 * S.s, 0, 18), Position = UDim2.fromOffset(S.s, S.s), TextWrapped = false, ZIndex = z + 2, Parent = panel })
	UiKit.text("caption", {
		Text = "First matching rule wins.",
		Size = UDim2.new(1, -2 * S.s, 0, 18),
		Position = UDim2.fromOffset(S.s, S.s + 18),
		TextColor3 = DIM,
		ZIndex = z + 2,
		Parent = panel,
	})
	local list = UiKit.frame({ Name = "List", Size = UDim2.new(1, -2 * S.s, 1, -(S.s + 44)), Position = UDim2.fromOffset(S.s, S.s + 42), BackgroundTransparency = 1, ZIndex = z + 2, Parent = panel })
	UiKit.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, S.s), Parent = list })
	for i, r in rules do
		UiKit.text("body", {
			Name = "Rule" .. i,
			Text = richRule(i, r),
			RichText = true,
			TextSize = 14,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextYAlignment = Enum.TextYAlignment.Top,
			LayoutOrder = i,
			ZIndex = z + 2,
			Parent = list,
		})
	end
end

-- Flat list row. UiKit's hover tint is invisible on the white field, so the
-- row gets its own grey wash.
local function row(parent: Instance, name: string, y: number, h: number, isSel: boolean, z: number, onClick: () -> ()): TextButton
	local b = UiKit.button({
		name = name,
		text = "",
		size = UDim2.new(1, 0, 0, h),
		position = UDim2.fromOffset(0, y),
		parent = parent,
		color = if isSel then C.select else C.field,
		bevel = false,
		zindex = z,
		onClick = onClick,
	})
	local wash = UiKit.frame({ Name = "Hover", Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.face, BackgroundTransparency = 0.35, Visible = false, ZIndex = z + 1, Parent = b })
	b.MouseEnter:Connect(function()
		wash.Visible = b.Active and not isSel
	end)
	b.MouseLeave:Connect(function()
		wash.Visible = false
	end)
	return b
end

local function cell(parent: Instance, c: Col, text: string, ink: Color3, z: number): TextLabel
	return UiKit.text("mono", {
		Text = text,
		TextSize = 14,
		Size = UDim2.new(0, c.w, 1, 0),
		Position = UDim2.fromOffset(c.x, 0),
		TextColor3 = ink,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = z,
		Parent = parent,
	})
end

function View.render(root: Frame, v: { [string]: any }, api: { act: (string, any, any) -> () }, z: number)
	local focus = focusName(root)
	UiKit.clear(root)
	local w = if root.Size.X.Offset > 0 then root.Size.X.Offset else 620
	local h = if root.Size.Y.Offset > 0 then root.Size.Y.Offset else 250
	local files = v.files :: { any }
	-- a new stage drops the old selection
	local names = {}
	for _, f in files do
		table.insert(names, f.name)
	end
	local key = table.concat((v.rules :: { string }), "|") .. "#" .. table.concat(names, "|")
	if key ~= lastKey then
		selected = nil
		lastKey = key
	end
	-- and a file the server has since sorted cannot stay selected
	local selName: string? = nil
	local firstOpen: string? = nil
	local done = 0
	for _, f in files do
		if f.bin ~= nil then
			done += 1
		else
			firstOpen = firstOpen or "File" .. tostring(f.id)
			if f.id == selected then
				selName = f.name
			end
		end
	end
	if not selName then
		selected = nil
	end

	rulesPanel(root, v.rules, h, z)

	-- file list (details view)
	local fx = RULES_W + S.s
	local fw = w - fx
	UiKit.text("title", { Text = "FILES", Size = UDim2.fromOffset(80, 18), Position = UDim2.fromOffset(fx, 0), TextWrapped = false, ZIndex = z, Parent = root })
	UiKit.text("caption", {
		Text = if selName then "Selected: " .. selName else string.format("%d of %d sorted", done, #files),
		Size = UDim2.fromOffset(fw - 80, 18),
		Position = UDim2.fromOffset(fx + 80, 0),
		TextColor3 = if selName then C.text else DIM,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = z,
		Parent = root,
	})
	local listH = h - 20 - BIN_H - S.s
	local well = UiKit.frame({ Name = "FileList", Size = UDim2.fromOffset(fw, listH), Position = UDim2.fromOffset(fx, 20), BackgroundColor3 = C.field, ZIndex = z, Parent = root })
	UiKit.bevel(well, true)
	local inner = UiKit.frame({ Name = "Rows", Size = UDim2.new(1, -4, 1, -4), Position = UDim2.fromOffset(2, 2), BackgroundTransparency = 1, ZIndex = z + 2, Parent = well })
	local strip = UiKit.frame({ Name = "Columns", Size = UDim2.new(1, 0, 0, HEAD_H), BackgroundColor3 = C.face, ZIndex = z + 2, Parent = inner })
	UiKit.bevel(strip)
	for _, c in COLS do
		UiKit.text("caption", { Text = c.title, Font = UiKit.FONT_BOLD, TextSize = 13, Size = UDim2.new(0, c.w, 1, 0), Position = UDim2.fromOffset(c.x, 0), TextWrapped = false, ZIndex = z + 4, Parent = strip })
	end
	local rowH = math.min(28, math.floor((listH - 4 - HEAD_H) / math.max(1, #files)))
	for i, f in files do
		local sorted = f.bin ~= nil
		local isSel = selected == f.id
		local hinted = v.highlight == f.id
		local b = row(inner, "File" .. tostring(f.id), HEAD_H + (i - 1) * rowH, rowH, isSel, z + 2, function()
			if not sorted then
				selected = f.id
				View.render(root, v, api, z) -- local re-render for selection
			end
		end)
		-- state is spelled out: > selected, ! hinted, bin name once sorted
		local ink = if isSel then C.white elseif sorted then DIM else C.text
		cell(b, MARK, if isSel then ">" elseif hinted then "!" else "", ink, z + 4)
		cell(b, COLS[1], f.name, ink, z + 4)
		cell(b, COLS[2], tostring(f.year), ink, z + 4)
		cell(b, COLS[3], f.dept, ink, z + 4)
		local status = if sorted then (if f.bin == "purge" then "PURGED" else "KEPT") elseif f.tag ~= "" then f.tag else "-"
		cell(b, COLS[4], status, ink, z + 4)
		if hinted then
			local edge = UiKit.frame({ Name = "HintEdge", Size = UDim2.new(1, -4, 1, -4), Position = UDim2.fromOffset(2, 2), BackgroundTransparency = 1, ZIndex = z + 5, Parent = b })
			UiKit.stroke(edge, C.warn, 0, 2)
		end
		UiKit.setEnabled(b, not sorted)
	end

	-- bins: greyed out until a file is selected
	local bw = math.floor((fw - S.s) / 2)
	local function bin(name: string, label: string, target: string, color: Color3, x: number)
		local on = selected ~= nil
		local b = UiKit.button({
			name = name,
			text = label,
			size = UDim2.fromOffset(bw, BIN_H),
			position = UDim2.fromOffset(x, h - BIN_H),
			parent = root,
			color = if on then color else C.face,
			textColor = if on then C.white else C.text,
			zindex = z,
			onClick = function()
				if selected then
					local id = selected
					selected = nil
					api.act("sort", id, target)
				end
			end,
		})
		UiKit.setEnabled(b, on)
	end
	bin("BinPurge", "PURGE  (delete)", "purge", C.bad, fx)
	bin("BinKeep", "KEEP  (archive)", "keep", C.good, fx + bw + S.s)
	refocus(root, focus, firstOpen)
end

return View
