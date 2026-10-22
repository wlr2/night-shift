--!strict
-- PROCESS CLEANUP view: rules, a task-manager style process list, file
-- groups that unlock when the right processes are ended.

local UiKit = require(script.Parent.Parent.Ui.UiKit)
local C = UiKit.C

local View = {}
local selected: number? = nil

function View.render(root: Frame, v: { [string]: any }, api: { act: (string, any, any) -> () }, z: number)
	UiKit.clear(root)
	local rules = UiKit.frame({ Size = UDim2.fromOffset(196, 250), BackgroundColor3 = C.field, ZIndex = z, Parent = root })
	UiKit.bevel(rules, true)
	UiKit.label({ Text = "RULES", Size = UDim2.new(1, -10, 0, 20), Position = UDim2.fromOffset(6, 4), Font = UiKit.FONT_BOLD, ZIndex = z + 1, Parent = rules })
	for i, r in v.rules :: { string } do
		UiKit.label({ Text = "- " .. r, Size = UDim2.new(1, -12, 0, 54), Position = UDim2.fromOffset(6, 24 + (i - 1) * 56), TextSize = 14, ZIndex = z + 1, Parent = rules })
	end
	-- process table
	local tbl = UiKit.frame({ Size = UDim2.fromOffset(270, 210), Position = UDim2.fromOffset(204, 0), BackgroundColor3 = C.field, ZIndex = z, Parent = root })
	UiKit.bevel(tbl, true)
	UiKit.label({ Text = "PID    NAME               OWNER     CPU", Size = UDim2.new(1, -8, 0, 18), Position = UDim2.fromOffset(4, 2), Font = UiKit.FONT_MONO, TextSize = 12, ZIndex = z + 1, Parent = tbl })
	local rowH = math.min(26, math.floor(186 / math.max(1, #v.procs)))
	for i, p in v.procs do
		local isSel = selected == p.pid
		local b = UiKit.button({
			text = string.format("%-6d %-18s %-9s %3d%%", p.pid, string.sub(p.name, 1, 18), p.owner, p.cpu),
			size = UDim2.new(1, -8, 0, rowH - 2),
			position = UDim2.fromOffset(4, 20 + (i - 1) * rowH),
			parent = tbl,
			color = if p.ended then Color3.fromRGB(190, 190, 186) elseif isSel then C.select else C.field,
			textColor = if isSel then C.white else C.text,
			font = UiKit.FONT_MONO,
			textSize = 12,
			zindex = z + 1,
			bevel = false,
			onClick = function()
				if not p.ended then
					selected = p.pid
					View.render(root, v, api, z)
				end
			end,
		})
		b.TextXAlignment = Enum.TextXAlignment.Left
		if p.ended then
			b.Text = b.Text .. "  ENDED"
			UiKit.setEnabled(b, false)
		end
		if v.highlight == p.pid then
			UiKit.new("UIStroke", { Color = Color3.fromRGB(255, 170, 0), Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = b })
		end
	end
	local endBtn = UiKit.button({
		text = "END PROCESS",
		size = UDim2.fromOffset(270, 34),
		position = UDim2.fromOffset(204, 216),
		parent = root,
		color = C.bad,
		textColor = C.white,
		zindex = z,
		onClick = function()
			if selected then
				local pid = selected
				selected = nil
				api.act("kill", pid, nil)
			end
		end,
	})
	UiKit.setEnabled(endBtn, selected ~= nil)
	-- file groups
	UiKit.label({ Text = "FILE GROUPS", Size = UDim2.fromOffset(140, 20), Position = UDim2.fromOffset(482, 0), Font = UiKit.FONT_BOLD, ZIndex = z, Parent = root })
	for i, g in v.groups do
		local text = if g.deleted then g.name .. "\nDELETED" elseif g.unlocked then g.name .. "\nDELETE" else g.name .. "\nLOCKED"
		local b = UiKit.button({
			text = text,
			size = UDim2.fromOffset(138, 52),
			position = UDim2.fromOffset(482, 22 + (i - 1) * 58),
			parent = root,
			color = if g.deleted then Color3.fromRGB(170, 170, 166) elseif g.unlocked then C.warn else C.faceDark,
			textSize = 13,
			zindex = z,
			onClick = function()
				api.act("purge", i, nil)
			end,
		})
		UiKit.setEnabled(b, g.unlocked and not g.deleted)
	end
end

return View
