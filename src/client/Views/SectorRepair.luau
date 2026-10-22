--!strict
-- SECTOR REPAIR view: TARGET ORDER on top, current slots below. Click two
-- slots to swap them. Sectors show number+letter AND colour; slot state is
-- spelled out (OK / SWAP / HINT) rather than coloured.

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local UiKit = require(script.Parent.Parent.Ui.UiKit)
local C = UiKit.C
local S = UiKit.SPACE
local DIM = UiKit.C.textDim -- secondary text, 5:1 on the face

local SWATCH: { [string]: Color3 } = {
	amber = Color3.fromRGB(222, 160, 58),
	teal = Color3.fromRGB(52, 160, 160),
	rose = Color3.fromRGB(206, 96, 120),
	lime = Color3.fromRGB(136, 188, 70),
	violet = Color3.fromRGB(136, 96, 188),
	sky = Color3.fromRGB(86, 146, 214),
	sand = Color3.fromRGB(204, 186, 140),
	slate = Color3.fromRGB(110, 120, 136),
}

local TARGET_H = 52
local SLOT_H = 100

local View = {}
local first: number? = nil
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

-- colour bar + mono label, shared by the target cells and the slots
local function sector(parent: Instance, s: { label: string, color: string }, labelY: number, labelSize: number, ink: Color3, z: number)
	UiKit.frame({ Name = "Swatch", Size = UDim2.new(1, -12, 0, 10), Position = UDim2.fromOffset(6, 6), BackgroundColor3 = SWATCH[s.color] or C.faceDark, ZIndex = z, Parent = parent })
	UiKit.text("mono", {
		Text = s.label,
		TextSize = labelSize,
		Size = UDim2.new(1, 0, 0, labelSize + 6),
		Position = UDim2.fromOffset(0, labelY),
		TextColor3 = ink,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = false,
		ZIndex = z,
		Parent = parent,
	})
end

function View.render(root: Frame, v: { [string]: any }, api: { act: (string, any, any) -> () }, z: number)
	local focus = focusName(root)
	UiKit.clear(root)
	local w = if root.Size.X.Offset > 0 then root.Size.X.Offset else 620
	local h = if root.Size.Y.Offset > 0 then root.Size.Y.Offset else 250
	local n = #v.target
	-- a new stage (new target order) drops a half-made swap
	local labels = {}
	for i, s in v.target do
		labels[i] = s.label
	end
	local key = table.concat(labels, ",")
	if key ~= lastKey or (first and first > #v.current) then
		first = nil
		lastKey = key
	end
	local cw = math.min(92, math.floor((w - 20) / math.max(1, n)) - S.s)
	local x0 = (w - (n * (cw + S.s) - S.s)) // 2
	local y0 = math.max(0, (h - (20 + TARGET_H + 26 + 24 + SLOT_H)) // 2)

	-- target order: sunken read-only cells with slot numbers under them
	UiKit.text("title", { Text = "TARGET ORDER", Size = UDim2.fromOffset(200, 18), Position = UDim2.fromOffset(x0, y0), TextWrapped = false, ZIndex = z, Parent = root })
	for i, s in v.target do
		local x = x0 + (i - 1) * (cw + S.s)
		local f = UiKit.frame({ Name = "Target" .. i, Size = UDim2.fromOffset(cw, TARGET_H), Position = UDim2.fromOffset(x, y0 + 20), BackgroundColor3 = C.field, ZIndex = z, Parent = root })
		UiKit.bevel(f, true)
		sector(f, s, 20, 20, C.text, z + 2)
		UiKit.text("mono", {
			Text = "SLOT " .. i,
			TextSize = 14,
			Size = UDim2.fromOffset(cw, 18),
			Position = UDim2.fromOffset(x, y0 + 20 + TARGET_H + S.xs),
			TextColor3 = DIM,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextWrapped = false,
			ZIndex = z,
			Parent = root,
		})
	end

	-- drive sectors: raised slot buttons
	local sy = y0 + 20 + TARGET_H + 26
	UiKit.text("title", { Text = "DRIVE SECTORS", Size = UDim2.fromOffset(160, 18), Position = UDim2.fromOffset(x0, sy), TextWrapped = false, ZIndex = z, Parent = root })
	UiKit.text("caption", {
		Text = if first then string.format("Slot %d selected. Pick the slot to swap it with.", first) else "Select two slots to swap them.",
		Size = UDim2.fromOffset(math.max(0, w - (x0 + 168)), 18),
		Position = UDim2.fromOffset(x0 + 168, sy),
		TextColor3 = if first then C.text else DIM,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = z,
		Parent = root,
	})
	local hl = v.highlight
	for i, s in v.current do
		local isFirst = first == i
		local hinted = typeof(hl) == "table" and (hl[1] == i or hl[2] == i)
		local b = UiKit.button({
			name = "Slot" .. i,
			text = "",
			size = UDim2.fromOffset(cw, SLOT_H),
			position = UDim2.fromOffset(x0 + (i - 1) * (cw + S.s), sy + 24),
			parent = root,
			color = if isFirst then C.select else C.face,
			zindex = z,
			onClick = function()
				if first == nil then
					first = i
					View.render(root, v, api, z)
				elseif first == i then
					first = nil
					View.render(root, v, api, z)
				else
					local a = first
					first = nil
					api.act("swap", a, i)
				end
			end,
		})
		sector(b, s, 24, 22, if isFirst then C.white else C.text, z + 2)
		-- status line: SWAP (picked), HINT, OK (aligned)
		local status = if isFirst then "SWAP" elseif hinted then "HINT" elseif s.ok then "OK" else ""
		UiKit.text("title", {
			Name = "State",
			Text = status,
			Size = UDim2.fromOffset(52, 18),
			Position = UDim2.new(0.5, -26, 1, -(S.s + 20)),
			BackgroundTransparency = if hinted and not isFirst then 0 else 1,
			BackgroundColor3 = C.amber,
			TextColor3 = if isFirst then C.amber elseif s.ok and not hinted then C.good else C.text,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextWrapped = false,
			ZIndex = z + 3,
			Parent = b,
		})
		if hinted then
			local edge = UiKit.frame({ Name = "HintEdge", Size = UDim2.new(1, -4, 1, -4), Position = UDim2.fromOffset(2, 2), BackgroundTransparency = 1, ZIndex = z + 3, Parent = b })
			UiKit.stroke(edge, C.warn, 0, 2)
		end
	end
	refocus(root, focus, "Slot1")
end

function View.reset()
	first = nil
end

return View
