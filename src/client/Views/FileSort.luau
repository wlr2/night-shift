--!strict
-- FILE SORTING view: click a file, then PURGE or KEEP (no dragging needed).

local UiKit = require(script.Parent.Parent.Ui.UiKit)
local C = UiKit.C

local View = {}
local selected: number? = nil
local lastKey = ""

function View.render(root: Frame, v: { [string]: any }, api: { act: (string, any, any) -> () }, z: number)
	UiKit.clear(root)
	local key = table.concat((v.rules :: { string }), "|")
	if key ~= lastKey then
		selected = nil
		lastKey = key
	end
	-- rules panel
	local rules = UiKit.frame({ Size = UDim2.new(0, 210, 1, 0), BackgroundColor3 = C.field, ZIndex = z, Parent = root })
	UiKit.bevel(rules, true)
	UiKit.label({ Text = "RULES (top wins)", Size = UDim2.new(1, -12, 0, 22), Position = UDim2.fromOffset(6, 4), Font = UiKit.FONT_BOLD, TextSize = 15, ZIndex = z + 1, Parent = rules })
	for i, r in v.rules :: { string } do
		UiKit.label({ Text = i .. ". " .. r, Size = UDim2.new(1, -12, 0, 46), Position = UDim2.fromOffset(6, 26 + (i - 1) * 48), TextSize = 14, ZIndex = z + 1, Parent = rules })
	end
	-- files grid
	local grid = UiKit.frame({ Size = UDim2.new(1, -350, 1, 0), Position = UDim2.fromOffset(218, 0), BackgroundTransparency = 1, ZIndex = z, Parent = root })
	local layout = UiKit.new("UIGridLayout", { CellSize = UDim2.fromOffset(122, 76), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })
	local _ = layout
	for i, f in v.files do
		local sorted = f.bin ~= nil
		local isSel = selected == f.id
		local hinted = v.highlight == f.id
		local text = string.format("%s\n%d  %s%s", f.name, f.year, f.dept, if f.tag ~= "" then "\n[" .. f.tag .. "]" else "")
		if sorted then
			text = f.name .. "\n-> " .. string.upper(f.bin)
		end
		local b = UiKit.button({
			text = text,
			size = UDim2.fromOffset(122, 76),
			parent = grid,
			textSize = 13,
			font = UiKit.FONT,
			color = if sorted then Color3.fromRGB(180, 180, 176) elseif isSel then Color3.fromRGB(255, 240, 170) else C.field,
			zindex = z + 1,
			onClick = function()
				if not sorted then
					selected = f.id
					View.render(root, v, api, z) -- local re-render for selection
				end
			end,
		})
		b.LayoutOrder = i
		if hinted then
			UiKit.new("UIStroke", { Color = Color3.fromRGB(255, 170, 0), Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = b })
		end
		UiKit.setEnabled(b, not sorted)
	end
	-- bins
	local function bin(label: string, target: string, color: Color3, y: number)
		local b = UiKit.button({
			text = label,
			size = UDim2.fromOffset(122, 110),
			position = UDim2.new(1, -124, 0, y),
			parent = root,
			color = color,
			textColor = C.white,
			textSize = 20,
			zindex = z + 1,
			onClick = function()
				if selected then
					api.act("sort", selected, target)
					selected = nil
				end
			end,
		})
		UiKit.setEnabled(b, selected ~= nil)
	end
	-- clear previous bins on re-render (root is rebuilt by caller normally)
	bin("PURGE\n(delete)", "purge", C.bad, 0)
	bin("KEEP\n(archive)", "keep", C.good, 128)
	UiKit.label({
		Text = if selected then "Selected file - choose a bin" else "Select a file",
		Size = UDim2.new(0, 122, 0, 18),
		Position = UDim2.new(1, -124, 1, -14),
		TextSize = 12,
		ZIndex = z + 1,
		Parent = root,
	})
end

return View
