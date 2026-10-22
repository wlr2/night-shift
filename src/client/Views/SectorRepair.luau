--!strict
-- SECTOR REPAIR view: TARGET ORDER on top, current slots below. Click two
-- slots to swap them. Sectors show number+letter AND colour.

local UiKit = require(script.Parent.Parent.Ui.UiKit)
local C = UiKit.C

local SWATCH: { [string]: Color3 } = {
	amber = Color3.fromRGB(230, 160, 40),
	teal = Color3.fromRGB(40, 170, 170),
	rose = Color3.fromRGB(220, 90, 120),
	lime = Color3.fromRGB(140, 200, 60),
	violet = Color3.fromRGB(140, 90, 200),
	sky = Color3.fromRGB(80, 150, 230),
	sand = Color3.fromRGB(210, 190, 140),
	slate = Color3.fromRGB(110, 120, 140),
}

local View = {}
local first: number? = nil

local function cell(parent: Instance, s: { label: string, color: string }, x: number, y: number, w: number, z: number): Frame
	local f = UiKit.frame({ Size = UDim2.fromOffset(w, 64), Position = UDim2.fromOffset(x, y), BackgroundColor3 = C.field, ZIndex = z, Parent = parent })
	UiKit.bevel(f, true)
	UiKit.frame({ Size = UDim2.new(1, -8, 0, 14), Position = UDim2.fromOffset(4, 4), BackgroundColor3 = SWATCH[s.color] or C.faceDark, ZIndex = z + 1, Parent = f })
	UiKit.label({ Text = s.label, Size = UDim2.new(1, 0, 0, 36), Position = UDim2.fromOffset(0, 22), TextXAlignment = Enum.TextXAlignment.Center, Font = UiKit.FONT_MONO, TextSize = 22, ZIndex = z + 1, Parent = f })
	return f
end

function View.render(root: Frame, v: { [string]: any }, api: { act: (string, any, any) -> () }, z: number)
	UiKit.clear(root)
	local n = #v.target
	local w = math.min(92, math.floor(600 / n) - 8)
	local x0 = math.floor((620 - n * (w + 8)) / 2)
	UiKit.label({ Text = "TARGET ORDER", Size = UDim2.new(1, 0, 0, 20), Position = UDim2.fromOffset(x0, 0), Font = UiKit.FONT_BOLD, ZIndex = z, Parent = root })
	for i, s in v.target do
		cell(root, s, x0 + (i - 1) * (w + 8), 22, w, z)
		UiKit.label({ Text = tostring(i), Size = UDim2.fromOffset(w, 16), Position = UDim2.fromOffset(x0 + (i - 1) * (w + 8), 88), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 13, ZIndex = z, Parent = root })
	end
	UiKit.label({ Text = "DRIVE SECTORS (click two to swap)", Size = UDim2.new(1, 0, 0, 20), Position = UDim2.fromOffset(x0, 112), Font = UiKit.FONT_BOLD, ZIndex = z, Parent = root })
	local hl = v.highlight
	for i, s in v.current do
		local b = UiKit.button({
			text = "",
			size = UDim2.fromOffset(w, 90),
			position = UDim2.fromOffset(x0 + (i - 1) * (w + 8), 136),
			parent = root,
			color = if first == i then Color3.fromRGB(255, 240, 170) else C.face,
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
		local inner = cell(b, s, 4, 4, w - 8, z + 2)
		local _ = inner
		UiKit.label({
			Text = if s.ok then "OK" else "",
			Size = UDim2.new(1, 0, 0, 18),
			Position = UDim2.new(0, 0, 1, -20),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = C.good,
			Font = UiKit.FONT_BOLD,
			ZIndex = z + 3,
			Parent = b,
		})
		if typeof(hl) == "table" and (hl[1] == i or hl[2] == i) then
			UiKit.new("UIStroke", { Color = Color3.fromRGB(255, 170, 0), Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = b })
		end
	end
end

function View.reset()
	first = nil
end

return View
