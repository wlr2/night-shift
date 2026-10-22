--!strict
-- MEMORY SEQUENCE view: plays the server's sequence whenever playId changes,
-- then accepts clicks. REPLAY restarts input (the small cost). A lit block
-- turns dark with an amber label and edge: a strong change in brightness and
-- shape, not just hue.

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local UiKit = require(script.Parent.Parent.Ui.UiKit)
local C = UiKit.C
local S = UiKit.SPACE
local DIM = UiKit.C.textDim -- secondary text, 5:1 on the face

local SCREEN = Color3.fromRGB(30, 36, 40) -- dark status readout
local PHOSPHOR = Color3.fromRGB(170, 214, 176)
local CELL = 70
local PANEL_W = 220

local LABELS = { "TL", "T", "TR", "L", "C", "R", "BL", "B", "BR" }

local View = {}
local lastPlay = -1
local lastSeqKey = ""
local playing = false
local playToken = 0
local litNow: number? = nil -- block lit by playback right now
local cells: { TextButton } = {}
-- the latest render's status widgets, so playback can update them even
-- after a re-render replaced the ones it started with
local statusLabel: TextLabel? = nil
local replayButton: TextButton? = nil

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

local function flash(b: TextButton?, on: boolean)
	local lit = if b then b:FindFirstChild("Lit") else nil
	if lit and lit:IsA("GuiObject") then
		lit.Visible = on
	end
end

local function showState()
	local st = statusLabel
	if st then
		st.Text = if playing then "WATCH" else "YOUR TURN"
		st.TextColor3 = if playing then C.amber else PHOSPHOR
	end
	local rb = replayButton
	if rb then
		UiKit.setEnabled(rb, not playing)
	end
end

function View.render(root: Frame, v: { [string]: any }, api: { act: (string, any, any) -> () }, z: number)
	local focus = focusName(root)
	UiKit.clear(root)
	cells = {}
	local w = if root.Size.X.Offset > 0 then root.Size.X.Offset else 620
	local h = if root.Size.Y.Offset > 0 then root.Size.Y.Offset else 250
	local gridW = 3 * CELL + 2 * S.s
	local trayW = gridW + 2 * S.s
	local x0 = (w - (trayW + S.xl + PANEL_W)) // 2
	local y0 = (h - trayW) // 2

	-- the nine blocks sit in a sunken tray
	local tray = UiKit.frame({ Name = "Blocks", Size = UDim2.fromOffset(trayW, trayW), Position = UDim2.fromOffset(x0, y0), BackgroundColor3 = C.faceDark, ZIndex = z, Parent = root })
	UiKit.bevel(tray, true)
	for i = 1, 9 do
		local col = (i - 1) % 3
		local rowN = (i - 1) // 3
		local b = UiKit.button({
			name = "Block" .. i,
			text = LABELS[i],
			size = UDim2.fromOffset(CELL, CELL),
			position = UDim2.fromOffset(S.s + col * (CELL + S.s), S.s + rowN * (CELL + S.s)),
			parent = tray,
			font = UiKit.FONT_PIXEL,
			textSize = 16,
			zindex = z + 2,
			onClick = function()
				if not playing then
					flash(cells[i], true)
					task.delay(0.15, function()
						flash(cells[i], false)
					end)
					api.act("press", i, nil)
				end
			end,
		})
		local lit = UiKit.frame({ Name = "Lit", Size = UDim2.new(1, -4, 1, -4), Position = UDim2.fromOffset(2, 2), BackgroundColor3 = C.select, Visible = playing and litNow == i, ZIndex = z + 6, Parent = b })
		UiKit.stroke(lit, C.amber, 0, 2)
		UiKit.text("title", { Text = LABELS[i], Size = UDim2.fromScale(1, 1), TextColor3 = C.amber, TextXAlignment = Enum.TextXAlignment.Center, TextWrapped = false, ZIndex = z + 7, Parent = lit })
		if v.highlight == i then
			-- hint: amber edge plus a HINT tag under the label
			local edge = UiKit.frame({ Name = "HintEdge", Size = UDim2.new(1, -4, 1, -4), Position = UDim2.fromOffset(2, 2), BackgroundTransparency = 1, ZIndex = z + 4, Parent = b })
			UiKit.stroke(edge, C.warn, 0, 2)
			UiKit.text("title", {
				Name = "HintTag",
				Text = "HINT",
				Size = UDim2.fromOffset(48, 18),
				Position = UDim2.new(0.5, -24, 1, -24),
				BackgroundTransparency = 0,
				BackgroundColor3 = C.amber,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextWrapped = false,
				ZIndex = z + 4,
				Parent = b,
			})
		end
		cells[i] = b
	end

	-- status panel: readout, input count, replay
	local px = x0 + trayW + S.xl
	local py = y0
	UiKit.text("title", { Text = "STATUS", Size = UDim2.fromOffset(PANEL_W, 18), Position = UDim2.fromOffset(px, py), TextWrapped = false, ZIndex = z, Parent = root })
	local screen = UiKit.frame({ Name = "Status", Size = UDim2.fromOffset(PANEL_W, 40), Position = UDim2.fromOffset(px, py + 20), BackgroundColor3 = SCREEN, ZIndex = z, Parent = root })
	UiKit.bevel(screen, true)
	statusLabel = UiKit.text("title", { Name = "State", Text = "", Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextWrapped = false, ZIndex = z + 2, Parent = screen })
	UiKit.text("title", { Text = "INPUT", Size = UDim2.fromOffset(120, 18), Position = UDim2.fromOffset(px, py + 72), TextWrapped = false, ZIndex = z, Parent = root })
	UiKit.text("mono", {
		Text = string.format("%d / %d", v.input, v.length),
		Size = UDim2.fromOffset(80, 18),
		Position = UDim2.fromOffset(px + PANEL_W - 80, py + 72),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextWrapped = false,
		ZIndex = z,
		Parent = root,
	})
	local len = math.max(1, v.length)
	local pw = math.floor((PANEL_W - (len - 1) * S.xs) / len)
	for i = 1, len do
		local done = i <= v.input
		local pip = UiKit.frame({ Size = UDim2.fromOffset(pw, 12), Position = UDim2.fromOffset(px + (i - 1) * (pw + S.xs), py + 94), BackgroundColor3 = if done then C.good else C.field, ZIndex = z, Parent = root })
		UiKit.bevel(pip, not done)
	end
	replayButton = UiKit.button({
		name = "Replay",
		text = "Replay sequence",
		size = UDim2.fromOffset(PANEL_W, 40),
		position = UDim2.fromOffset(px, py + 122),
		parent = root,
		zindex = z,
		onClick = function()
			if not playing then
				api.act("replay", nil, nil)
			end
		end,
	})
	UiKit.text("caption", {
		Text = "Replaying restarts your input.",
		Size = UDim2.fromOffset(PANEL_W, 18),
		Position = UDim2.fromOffset(px, py + 168),
		TextColor3 = DIM,
		ZIndex = z,
		Parent = root,
	})
	UiKit.text("caption", {
		Text = "Replays used: " .. tostring(v.replays),
		Size = UDim2.fromOffset(PANEL_W, 18),
		Position = UDim2.fromOffset(px, py + 188),
		TextColor3 = DIM,
		ZIndex = z,
		Parent = root,
	})

	-- playback when the server bumps playId or a new sequence arrives
	local seqKey = table.concat(v.seq, ",")
	if v.playId ~= lastPlay or seqKey ~= lastSeqKey then
		lastPlay = v.playId
		lastSeqKey = seqKey
		playToken += 1
		local my = playToken
		local seq = v.seq :: { number }
		local slow = v.highlight ~= nil
		playing = true
		task.spawn(function()
			task.wait(0.6)
			for _, idx in seq do
				if my ~= playToken then
					return
				end
				litNow = idx
				flash(cells[idx], true)
				UiKit.click()
				task.wait(if slow then 0.75 else 0.5)
				litNow = nil
				flash(cells[idx], false)
				task.wait(0.18)
			end
			if my == playToken then
				playing = false
				showState()
			end
		end)
	end
	showState()
	refocus(root, focus, "Block1")
end

return View
