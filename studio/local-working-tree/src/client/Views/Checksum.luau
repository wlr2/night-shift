--!strict
-- CHECKSUM MATCHING view: target pattern + record list (symbols as text).

local UiKit = require(script.Parent.Parent.Ui.UiKit)
local C = UiKit.C

local View = {}

function View.render(root: Frame, v: { [string]: any }, api: { act: (string, any, any) -> () }, z: number)
	UiKit.clear(root)
	local box = UiKit.frame({ Size = UDim2.fromOffset(190, 250), BackgroundColor3 = Color3.fromRGB(20, 24, 30), ZIndex = z, Parent = root })
	UiKit.bevel(box, true)
	UiKit.label({ Text = "TARGET CHECKSUM", Size = UDim2.new(1, -10, 0, 24), Position = UDim2.fromOffset(8, 8), TextColor3 = Color3.fromRGB(150, 220, 150), Font = UiKit.FONT_BOLD, ZIndex = z + 1, Parent = box })
	UiKit.label({ Text = v.target, Size = UDim2.new(1, -10, 0, 70), Position = UDim2.fromOffset(5, 40), TextColor3 = Color3.fromRGB(120, 255, 140), Font = UiKit.FONT_MONO, TextSize = 30, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = z + 1, Parent = box })
	UiKit.label({
		Text = string.format("Verified: %d / %d", v.matched, v.need),
		Size = UDim2.new(1, -10, 0, 24),
		Position = UDim2.fromOffset(8, 130),
		TextColor3 = Color3.fromRGB(200, 200, 200),
		ZIndex = z + 1,
		Parent = box,
	})
	UiKit.label({ Text = "Symbols: # hash  @ at  % pct  & and  + plus  = eq  * star  ? q", Size = UDim2.new(1, -12, 0, 80), Position = UDim2.fromOffset(8, 160), TextColor3 = Color3.fromRGB(150, 150, 150), TextSize = 13, ZIndex = z + 1, Parent = box })
	local list = UiKit.frame({ Size = UDim2.new(1, -200, 1, 0), Position = UDim2.fromOffset(200, 0), BackgroundTransparency = 1, ZIndex = z, Parent = root })
	local n = #v.records
	local rowH = math.min(44, math.floor(250 / n) - 4)
	for i, r in v.records do
		local b = UiKit.button({
			text = "",
			size = UDim2.new(1, 0, 0, rowH),
			position = UDim2.fromOffset(0, (i - 1) * (rowH + 4)),
			parent = list,
			color = C.field,
			zindex = z,
			onClick = function()
				api.act("match", r.id, nil)
			end,
		})
		UiKit.label({ Text = r.name, Size = UDim2.new(0.55, 0, 1, 0), Position = UDim2.fromOffset(10, 0), TextSize = 15, ZIndex = z + 2, Parent = b })
		UiKit.label({ Text = r.pattern, Size = UDim2.new(0.42, 0, 1, 0), Position = UDim2.fromScale(0.56, 0), Font = UiKit.FONT_MONO, TextSize = 22, ZIndex = z + 2, Parent = b })
		if v.highlight == r.id then
			UiKit.new("UIStroke", { Color = Color3.fromRGB(255, 170, 0), Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = b })
		end
	end
end

return View
