--!strict
-- MEMORY SEQUENCE view: plays the server's sequence whenever playId changes,
-- then accepts clicks. REPLAY restarts input (the small cost).

local UiKit = require(script.Parent.Parent.Ui.UiKit)
local C = UiKit.C

local View = {}
local lastPlay = -1
local lastSeqKey = ""
local playing = false
local playToken = 0
local cells: { TextButton } = {}

local LABELS = { "TL", "T", "TR", "L", "C", "R", "BL", "B", "BR" }

local function flash(b: TextButton, on: boolean)
	b.BackgroundColor3 = if on then Color3.fromRGB(255, 220, 80) else Color3.fromRGB(70, 80, 100)
end

function View.render(root: Frame, v: { [string]: any }, api: { act: (string, any, any) -> () }, z: number)
	UiKit.clear(root)
	cells = {}
	local size = 72
	local gx = 150
	for i = 1, 9 do
		local col = (i - 1) % 3
		local row = (i - 1) // 3
		local b = UiKit.button({
			text = LABELS[i],
			size = UDim2.fromOffset(size, size),
			position = UDim2.fromOffset(gx + col * (size + 8), 6 + row * (size + 8)),
			parent = root,
			color = Color3.fromRGB(70, 80, 100),
			textColor = Color3.fromRGB(200, 210, 230),
			zindex = z,
			onClick = function()
				if not playing then
					flash(cells[i], true)
					task.delay(0.15, function()
						if cells[i] then
							flash(cells[i], false)
						end
					end)
					api.act("press", i, nil)
				end
			end,
		})
		cells[i] = b
		if v.highlight == i then
			UiKit.new("UIStroke", { Color = Color3.fromRGB(255, 120, 0), Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = b })
		end
	end
	local status = UiKit.label({
		Text = string.format("Input %d / %d", v.input, v.length),
		Size = UDim2.fromOffset(180, 30),
		Position = UDim2.fromOffset(420, 20),
		Font = UiKit.FONT_BOLD,
		TextSize = 18,
		ZIndex = z,
		Parent = root,
	})
	UiKit.button({
		text = "REPLAY\n(restarts input)",
		size = UDim2.fromOffset(160, 64),
		position = UDim2.fromOffset(420, 70),
		parent = root,
		zindex = z,
		onClick = function()
			if not playing then
				api.act("replay", nil, nil)
			end
		end,
	})
	UiKit.label({ Text = "Replays used: " .. tostring(v.replays), Size = UDim2.fromOffset(180, 22), Position = UDim2.fromOffset(420, 140), TextSize = 14, ZIndex = z, Parent = root })
	-- playback when the server bumps playId or a new sequence arrives
	local seqKey = table.concat(v.seq, ",")
	if v.playId ~= lastPlay or seqKey ~= lastSeqKey then
		lastPlay = v.playId
		lastSeqKey = seqKey
		playToken += 1
		local my = playToken
		playing = true
		status.Text = "WATCH..."
		local slow = v.highlight ~= nil
		task.spawn(function()
			task.wait(0.6)
			for _, idx in v.seq do
				if my ~= playToken or not cells[idx] then
					return
				end
				flash(cells[idx], true)
				UiKit.click()
				task.wait(if slow then 0.75 else 0.5)
				if cells[idx] then
					flash(cells[idx], false)
				end
				task.wait(0.18)
			end
			if my == playToken then
				playing = false
				if status.Parent then
					status.Text = string.format("Your turn: %d / %d", v.input, v.length)
				end
			end
		end)
	elseif playing then
		status.Text = "WATCH..."
	end
	local _ = C
end

return View
