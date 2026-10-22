--!strict
-- SIGNAL ROUTING view: click tiles to rotate. Lit (amber) tiles carry the
-- purge signal from IN to OUT. Tiles draw their connectors as bars.

local UiKit = require(script.Parent.Parent.Ui.UiKit)
local C = UiKit.C

local BASE: { [string]: { number } } = { I = { 1, 3 }, L = { 1, 2 }, T = { 1, 2, 3 } }

local View = {}

local function dirs(kind: string, rot: number): { [number]: boolean }
	local out = {}
	local base: { number } = BASE[kind] or {}
	for _, d in base do
		out[(d - 1 + rot) % 4 + 1] = true
	end
	return out
end

function View.render(root: Frame, v: { [string]: any }, api: { act: (string, any, any) -> () }, z: number)
	UiKit.clear(root)
	local w, h = v.w, v.h
	local size = math.min(math.floor(240 / h), math.floor(520 / w), 60)
	local gx = math.floor((620 - w * size) / 2)
	local gy = math.floor((250 - h * size) / 2)
	local function arrow(text: string, row: number, left: boolean)
		UiKit.label({
			Text = text,
			Size = UDim2.fromOffset(46, size),
			Position = UDim2.fromOffset(if left then gx - 50 else gx + w * size + 4, gy + (row - 1) * size),
			TextXAlignment = Enum.TextXAlignment.Center,
			Font = UiKit.FONT_BOLD,
			TextSize = 16,
			TextColor3 = C.bad,
			ZIndex = z,
			Parent = root,
		})
	end
	arrow("IN >", v.inRow, true)
	arrow("> OUT", v.outRow, false)
	for y = 1, h do
		for x = 1, w do
			local i = (y - 1) * w + x
			local t = v.tiles[i]
			local lit = t.lit
			local b = UiKit.button({
				text = "",
				size = UDim2.fromOffset(size - 2, size - 2),
				position = UDim2.fromOffset(gx + (x - 1) * size, gy + (y - 1) * size),
				parent = root,
				color = if lit then Color3.fromRGB(60, 52, 30) else Color3.fromRGB(40, 44, 52),
				zindex = z,
				bevel = false,
				onClick = function()
					api.act("rotate", i, nil)
				end,
			})
			local barColor = if lit then Color3.fromRGB(255, 190, 40) else Color3.fromRGB(150, 160, 175)
			local half = (size - 2) / 2
			local thick = math.max(6, math.floor(size / 6))
			UiKit.frame({ Size = UDim2.fromOffset(thick, thick), Position = UDim2.fromOffset(half - thick / 2, half - thick / 2), BackgroundColor3 = barColor, ZIndex = z + 1, Parent = b })
			for d in dirs(t.kind, t.rot) do
				local pos, sz
				if d == 1 then
					pos, sz = UDim2.fromOffset(half - thick / 2, 0), UDim2.fromOffset(thick, half)
				elseif d == 3 then
					pos, sz = UDim2.fromOffset(half - thick / 2, half), UDim2.fromOffset(thick, half)
				elseif d == 2 then
					pos, sz = UDim2.fromOffset(half, half - thick / 2), UDim2.fromOffset(half, thick)
				else
					pos, sz = UDim2.fromOffset(0, half - thick / 2), UDim2.fromOffset(half, thick)
				end
				UiKit.frame({ Size = sz, Position = pos, BackgroundColor3 = barColor, ZIndex = z + 1, Parent = b })
			end
			if v.highlight == i then
				UiKit.new("UIStroke", { Color = Color3.fromRGB(255, 120, 0), Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = b })
			end
		end
	end
end

return View
