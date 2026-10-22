--!strict
-- PROCESS CLEANUP view: rules, a task-manager style process list, file
-- groups that unlock when the right processes are ended. Every state is
-- spelled out (> selected, x ended, LOCKED / DELETE / DELETED), not only
-- coloured.

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local UiKit = require(script.Parent.Parent.Ui.UiKit)
local C = UiKit.C
local S = UiKit.SPACE
local DIM = UiKit.C.textDim -- secondary text, 5:1 on the face

local RULES_W = 172
local TABLE_W = 300
local END_H = 40
local HEAD_H = 20

type Col = { title: string, x: number, w: number, right: boolean? }
-- task-manager columns, x relative to the row
local MARK: Col = { title = "", x = 4, w = 12 }
local PID: Col = { title = "PID", x = 18, w = 36 }
local NAME: Col = { title = "NAME", x = 58, w = 128 }
local OWNER: Col = { title = "OWNER", x = 190, w = 64 }
local CPU: Col = { title = "CPU", x = 256, w = 34, right = true }

local View = {}
local selected: number? = nil

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

local function escape(text: string): string
	local s = string.gsub(text, "&", "&amp;")
	s = string.gsub(s, "<", "&lt;")
	s = string.gsub(s, ">", "&gt;")
	return s
end

local function rulesPanel(root: Frame, rules: { string }, h: number, z: number)
	local panel = UiKit.frame({ Name = "Rules", Size = UDim2.fromOffset(RULES_W, h), BackgroundColor3 = C.field, ZIndex = z, Parent = root })
	UiKit.bevel(panel, true)
	UiKit.text("title", { Text = "RULES", Size = UDim2.new(1, -2 * S.s, 0, 18), Position = UDim2.fromOffset(S.s, S.s), TextWrapped = false, ZIndex = z + 2, Parent = panel })
	local list = UiKit.frame({ Name = "List", Size = UDim2.new(1, -2 * S.s, 1, -(S.s + 30)), Position = UDim2.fromOffset(S.s, S.s + 24), BackgroundTransparency = 1, ZIndex = z + 2, Parent = panel })
	UiKit.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, S.s), Parent = list })
	for i, r in rules do
		-- leading verb (END / NEVER) in bold
		local text = string.gsub(escape(r), "^(%u+)", "<b>%1</b>")
		UiKit.text("body", {
			Name = "Rule" .. i,
			Text = text,
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

local function cell(parent: Instance, c: Col, text: string, ink: Color3, z: number, rich: boolean?): TextLabel
	return UiKit.text("mono", {
		Text = text,
		TextSize = 14,
		RichText = rich == true,
		Size = UDim2.new(0, c.w, 1, 0),
		Position = UDim2.fromOffset(c.x, 0),
		TextColor3 = ink,
		TextXAlignment = if c.right then Enum.TextXAlignment.Right else Enum.TextXAlignment.Left,
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
	local procs = v.procs :: { any }
	-- a selection that ended or left the list (new stage) is dropped
	local selName: string? = nil
	for _, p in procs do
		if p.pid == selected and not p.ended then
			selName = string.format("%d  %s", p.pid, p.name) -- names repeat, PIDs do not
		end
	end
	if not selName then
		selected = nil
	end

	rulesPanel(root, v.rules, h, z)

	-- process table
	local tx = RULES_W + S.s
	local running = 0
	local firstOpen: string? = nil
	for _, p in procs do
		if not p.ended then
			running += 1
			firstOpen = firstOpen or "Proc" .. tostring(p.pid)
		end
	end
	UiKit.text("title", { Text = "PROCESSES", Size = UDim2.fromOffset(140, 18), Position = UDim2.fromOffset(tx, 0), TextWrapped = false, ZIndex = z, Parent = root })
	UiKit.text("caption", {
		Text = string.format("%d running", running),
		Size = UDim2.fromOffset(TABLE_W - 140, 18),
		Position = UDim2.fromOffset(tx + 140, 0),
		TextColor3 = DIM,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextWrapped = false,
		ZIndex = z,
		Parent = root,
	})
	local listH = h - 20 - END_H - S.s
	local well = UiKit.frame({ Name = "ProcessList", Size = UDim2.fromOffset(TABLE_W, listH), Position = UDim2.fromOffset(tx, 20), BackgroundColor3 = C.field, ZIndex = z, Parent = root })
	UiKit.bevel(well, true)
	local inner = UiKit.frame({ Name = "Rows", Size = UDim2.new(1, -4, 1, -4), Position = UDim2.fromOffset(2, 2), BackgroundTransparency = 1, ZIndex = z + 2, Parent = well })
	local strip = UiKit.frame({ Name = "Columns", Size = UDim2.new(1, 0, 0, HEAD_H), BackgroundColor3 = C.face, ZIndex = z + 2, Parent = inner })
	UiKit.bevel(strip)
	for _, c in { PID, NAME, OWNER, CPU } do
		UiKit.text("caption", {
			Text = c.title,
			Font = UiKit.FONT_BOLD,
			TextSize = 13,
			Size = UDim2.new(0, c.w, 1, 0),
			Position = UDim2.fromOffset(c.x, 0),
			TextXAlignment = if c.right then Enum.TextXAlignment.Right else Enum.TextXAlignment.Left,
			TextWrapped = false,
			ZIndex = z + 4,
			Parent = strip,
		})
	end
	local rowH = math.min(26, math.floor((listH - 4 - HEAD_H) / math.max(1, #procs)))
	for i, p in procs do
		local isSel = selected == p.pid
		local b = UiKit.button({
			name = "Proc" .. tostring(p.pid),
			text = "",
			size = UDim2.new(1, 0, 0, rowH),
			position = UDim2.fromOffset(0, HEAD_H + (i - 1) * rowH),
			parent = inner,
			color = if isSel then C.select else C.field,
			bevel = false,
			zindex = z + 2,
			onClick = function()
				if not p.ended then
					selected = p.pid
					View.render(root, v, api, z)
				end
			end,
		})
		-- UiKit's hover tint is invisible on the white field: grey wash instead
		local wash = UiKit.frame({ Name = "Hover", Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.face, BackgroundTransparency = 0.35, Visible = false, ZIndex = z + 3, Parent = b })
		b.MouseEnter:Connect(function()
			wash.Visible = b.Active and not isSel
		end)
		b.MouseLeave:Connect(function()
			wash.Visible = false
		end)
		local ink = if isSel then C.white elseif p.ended then DIM else C.text
		local hinted = v.highlight == p.pid
		cell(b, MARK, if isSel then ">" elseif p.ended then "x" elseif hinted then "!" else "", ink, z + 4)
		cell(b, PID, tostring(p.pid), ink, z + 4)
		cell(b, NAME, if p.ended then "<s>" .. escape(p.name) .. "</s>" else escape(p.name), ink, z + 4, true)
		cell(b, OWNER, p.owner, ink, z + 4)
		cell(b, CPU, if p.ended then "--" else string.format("%d%%", p.cpu), ink, z + 4)
		if hinted then
			local edge = UiKit.frame({ Name = "HintEdge", Size = UDim2.new(1, -4, 1, -4), Position = UDim2.fromOffset(2, 2), BackgroundTransparency = 1, ZIndex = z + 5, Parent = b })
			UiKit.stroke(edge, C.warn, 0, 2)
		end
		if p.ended then
			UiKit.setEnabled(b, false)
		end
	end
	local endBtn = UiKit.button({
		name = "EndProcess",
		text = if selName then "END " .. selName else "END PROCESS",
		size = UDim2.fromOffset(TABLE_W, END_H),
		position = UDim2.fromOffset(tx, h - END_H),
		parent = root,
		color = if selName then C.bad else C.face,
		textColor = if selName then C.white else C.text,
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

	-- file groups: LOCKED until a matching process ends, then DELETE
	local gx = tx + TABLE_W + S.s
	local gw = w - gx
	UiKit.text("title", { Text = "GROUPS", Size = UDim2.fromOffset(gw, 18), Position = UDim2.fromOffset(gx, 0), TextWrapped = false, ZIndex = z, Parent = root })
	local groups = v.groups :: { any }
	local gh = math.min(64, math.floor((h - 20 - (#groups - 1) * S.s) / math.max(1, #groups)))
	for i, g in groups do
		local open = g.unlocked and not g.deleted
		local b = UiKit.button({
			name = "Group" .. i,
			text = "",
			size = UDim2.fromOffset(gw, gh),
			position = UDim2.fromOffset(gx, 20 + (i - 1) * (gh + S.s)),
			parent = root,
			color = if open then C.amber else C.face,
			zindex = z,
			onClick = function()
				api.act("purge", i, nil)
			end,
		})
		local ink = if open then C.text else DIM
		UiKit.text("mono", {
			Text = if g.deleted then "<s>" .. escape(g.name) .. "</s>" else escape(g.name),
			RichText = true,
			TextSize = 14,
			Size = UDim2.new(1, -2 * S.s, 0, 18),
			Position = UDim2.fromOffset(S.s, S.s),
			TextColor3 = ink,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = z + 2,
			Parent = b,
		})
		UiKit.text("title", {
			Text = if g.deleted then "DELETED" elseif g.unlocked then "DELETE" else "LOCKED",
			Size = UDim2.new(1, -2 * S.s, 0, 18),
			Position = UDim2.new(0, S.s, 1, -(S.s + 18)),
			TextColor3 = ink,
			TextWrapped = false,
			ZIndex = z + 2,
			Parent = b,
		})
		UiKit.setEnabled(b, open)
	end
	refocus(root, focus, firstOpen)
end

return View
