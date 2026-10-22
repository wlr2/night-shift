--!strict
-- SIGNAL ROUTING view: click tiles to rotate. Tiles sit on a dark board and
-- draw their connectors as bars; lit tiles carry the purge signal from IN to
-- OUT. Lit wires are amber AND thicker with a large node, so the path also
-- reads by shape and brightness.

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local UiKit = require(script.Parent.Parent.Ui.UiKit)
local C = UiKit.C
local S = UiKit.SPACE

local BOARD = Color3.fromRGB(30, 36, 40)
local TILE = Color3.fromRGB(52, 60, 66)
local TILE_LIT = Color3.fromRGB(70, 64, 50)
local WIRE = Color3.fromRGB(112, 124, 132)
local GLOW = Color3.fromRGB(226, 186, 116)
local PAD = 6 -- board margin around the tiles
local LABEL_W = 60 -- IN / OUT label
local PORT = 80 -- room beside the board for the label and its stub wire

local BASE: { [string]: { number } } = { I = { 1, 3 }, L = { 1, 2 }, T = { 1, 2, 3 } }

local View = {}

-- Gamepad: every update rebuilds the view, so focus moves to the control
-- that replaces the one that had it (rotating a tile keeps it focused).
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

local function dirs(kind: string, rot: number): { [number]: boolean }
	local out = {}
	local base: { number } = BASE[kind] or {}
	for _, d in base do
		out[(d - 1 + rot) % 4 + 1] = true
	end
	return out
end

function View.render(root: Frame, v: { [string]: any }, api: { act: (string, any, any) -> () }, z: number)
	local focus = focusName(root)
	UiKit.clear(root)
	local w = if root.Size.X.Offset > 0 then root.Size.X.Offset else 620
	local h = if root.Size.Y.Offset > 0 then root.Size.Y.Offset else 250
	local gw, gh = v.w, v.h
	local size = math.min(math.floor((h - 2 * PAD + 2) / gh), math.floor((w - 2 * (PAD + PORT)) / gw), 60)
	local inner = size - 2 -- tiles keep a 2 px gap
	local gx = (w - (gw * size - 2)) // 2
	local gy = (h - (gh * size - 2)) // 2
	local thin = math.max(4, size // 8)
	local thick = math.max(6, size // 5)
	local half = inner // 2

	local board = UiKit.frame({
		Name = "Board",
		Size = UDim2.fromOffset(gw * size - 2 + 2 * PAD, gh * size - 2 + 2 * PAD),
		Position = UDim2.fromOffset(gx - PAD, gy - PAD),
		BackgroundColor3 = BOARD,
		ZIndex = z,
		Parent = root,
	})
	UiKit.bevel(board, true)

	-- IN / OUT ports: a label and a stub wire that lights with its tile
	local function port(text: string, row: number, left: boolean, lit: boolean)
		local y = gy + (row - 1) * size + half
		local wireW = PAD + S.l
		local band = if lit then thick else thin
		UiKit.frame({
			Name = text .. "Wire",
			Size = UDim2.fromOffset(wireW, band),
			Position = UDim2.fromOffset(if left then gx - wireW else gx + gw * size - 2, y - band // 2),
			BackgroundColor3 = if lit then GLOW else WIRE,
			ZIndex = z + 3,
			Parent = root,
		})
		UiKit.text("title", {
			Name = text .. "Label",
			Text = if left then text .. " >" else "> " .. text,
			Size = UDim2.fromOffset(LABEL_W, 18),
			Position = UDim2.fromOffset(if left then gx - wireW - S.xs - LABEL_W else gx + gw * size - 2 + wireW + S.xs, y - 9),
			TextXAlignment = if left then Enum.TextXAlignment.Right else Enum.TextXAlignment.Left,
			TextWrapped = false,
			ZIndex = z,
			Parent = root,
		})
	end
	local inTile = v.tiles[(v.inRow - 1) * gw + 1]
	local outTile = v.tiles[v.outRow * gw]
	port("IN", v.inRow, true, inTile ~= nil and inTile.lit == true)
	port("OUT", v.outRow, false, outTile ~= nil and outTile.lit == true and dirs(outTile.kind, outTile.rot)[2] == true)

	for y = 1, gh do
		for x = 1, gw do
			local i = (y - 1) * gw + x
			local t = v.tiles[i]
			local lit = t.lit == true
			local b = UiKit.button({
				name = "Tile" .. i,
				text = "",
				size = UDim2.fromOffset(inner, inner),
				position = UDim2.fromOffset(gx + (x - 1) * size, gy + (y - 1) * size),
				parent = root,
				color = if lit then TILE_LIT else TILE,
				zindex = z + 2,
				bevel = false,
				onClick = function()
					api.act("rotate", i, nil)
				end,
			})
			local bar = if lit then thick else thin
			local ink = if lit then GLOW else WIRE
			local node = if lit then thick + 6 else thin + 2
			UiKit.frame({ Name = "Node", Size = UDim2.fromOffset(node, node), Position = UDim2.fromOffset(half - node // 2, half - node // 2), BackgroundColor3 = ink, ZIndex = z + 3, Parent = b })
			for d in dirs(t.kind, t.rot) do
				local pos, sz
				if d == 1 then
					pos, sz = UDim2.fromOffset(half - bar // 2, 0), UDim2.fromOffset(bar, half)
				elseif d == 3 then
					pos, sz = UDim2.fromOffset(half - bar // 2, half), UDim2.fromOffset(bar, inner - half)
				elseif d == 2 then
					pos, sz = UDim2.fromOffset(half, half - bar // 2), UDim2.fromOffset(inner - half, bar)
				else
					pos, sz = UDim2.fromOffset(0, half - bar // 2), UDim2.fromOffset(half, bar)
				end
				UiKit.frame({ Name = "Wire", Size = sz, Position = pos, BackgroundColor3 = ink, ZIndex = z + 3, Parent = b })
			end
			if v.highlight == i then
				-- hint: amber edge plus a "!" tag in the corner, clear of the wires
				local edge = UiKit.frame({ Name = "HintEdge", Size = UDim2.new(1, -4, 1, -4), Position = UDim2.fromOffset(2, 2), BackgroundTransparency = 1, ZIndex = z + 4, Parent = b })
				UiKit.stroke(edge, C.warn, 0, 2)
				UiKit.text("title", {
					Name = "HintTag",
					Text = "!",
					Size = UDim2.fromOffset(14, 18),
					Position = UDim2.fromOffset(S.xs, S.xs),
					BackgroundTransparency = 0,
					BackgroundColor3 = C.amber,
					TextXAlignment = Enum.TextXAlignment.Center,
					TextWrapped = false,
					ZIndex = z + 4,
					Parent = b,
				})
			end
		end
	end
	refocus(root, focus, "Tile1")
end

return View
