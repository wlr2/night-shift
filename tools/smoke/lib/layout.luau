--!nocheck
-- Approximate 2D GUI layout for PlayerGui, so AbsoluteSize / AbsolutePosition
-- / TextBounds have plausible values and the legibility sweep can measure
-- effective text sizes. It is NOT Roblox's layout engine. Modelled:
--   UDim2 Size/Position, AnchorPoint, UIScale (scales the subtree about the
--   object's anchor point; on a ScreenGui about the top-left), UIPadding,
--   UISizeConstraint, UIAspectRatioConstraint, UIListLayout, UIGridLayout,
--   AutomaticSize (one re-layout), ScrollingFrame canvas offset + clipping,
--   ClipsDescendants, Visible / ScreenGui.Enabled, IgnoreGuiInset (58 px).
-- Text: width ~= chars x TextSize x per-family factor, height = lines x
-- TextSize, greedy word wrap; TextScaled picks the largest size <= 100 that
-- fits, clamped by UITextSizeConstraint.
-- Not modelled: rotation, UIFlexItem, UIPageLayout/UITableLayout, real glyph
-- metrics, RichText sizing tags, the one-frame AbsoluteSize latency.

local roblox = require("@lune/roblox")
local Api = require("./api")
local Rt = require("./rt")

local V2 = roblox.Vector2

local Layout = {}

Layout.viewport = { w = 1366, h = 768 }
Layout.TOP_INSET = 58

local recs = Rt.recs

local function P(r: any, key: string): any
	local m = r.impl.members[key]
	if not m then
		return nil
	end
	return Rt.readProp(r, key, m)
end
Layout.P = P

-- Lune datatypes cross into Rust on every field access (and v.X of a UDim2
-- allocates a new UDim), so decompose each stored value once.
local u2c = setmetatable({}, { __mode = "k" }) :: any
local function U2(v: any): (number, number, number, number)
	local c = u2c[v]
	if not c then
		local x, y = v.X, v.Y
		c = { x.Scale, x.Offset, y.Scale, y.Offset }
		u2c[v] = c
	end
	return c[1], c[2], c[3], c[4]
end
local v2c = setmetatable({}, { __mode = "k" }) :: any
local function XY(v: any): (number, number)
	local c = v2c[v]
	if not c then
		c = { v.X, v.Y }
		v2c[v] = c
	end
	return c[1], c[2]
end
local u1c = setmetatable({}, { __mode = "k" }) :: any
local function U1(v: any): (number, number)
	local c = u1c[v]
	if not c then
		c = { v.Scale, v.Offset }
		u1c[v] = c
	end
	return c[1], c[2]
end

local function isA(r: any, cls: string): boolean
	return Api.isA(r.class, cls)
end

-- One scan of a node's children per layout pass: modifiers by class plus
-- the GuiObject children and the first list / grid layout.
Layout.passId = 0
local MOD_CLASSES = {
	UIPadding = true, UIScale = true, UISizeConstraint = true, UIAspectRatioConstraint = true,
	UITextSizeConstraint = true, UIFlexItem = true, UIListLayout = true, UIGridLayout = true,
}
local function mods(r: any): any
	if r._modsPass == Layout.passId and r._mods then
		return r._mods
	end
	local m = { kids = {} }
	for _, c in r.children do
		local cr = recs[c]
		local cls = cr.class
		if MOD_CLASSES[cls] then
			if m[cls] == nil then
				m[cls] = cr
			end
		elseif cr.impl.members.AbsoluteSize ~= nil and Api.isA(cls, "GuiObject") then
			table.insert(m.kids, cr)
		end
	end
	r._mods = m
	r._modsPass = Layout.passId
	return m
end
Layout.mods = mods

local function childOfClass(r: any, cls: string): any
	if MOD_CLASSES[cls] then
		return mods(r)[cls]
	end
	for _, c in r.children do
		local cr = recs[c]
		if cr.class == cls then
			return cr
		end
	end
	return nil
end

-- Fonts -----------------------------------------------------------------------

local SILKSCREEN_ID = "12187371840"
local WIDTH = {
	silkscreen = 0.78,
	arcade = 0.8,
	inconsolata = 0.55,
	robotomono = 0.6,
	ubuntu = 0.52,
	merriweather = 0.58,
	sourcesanspro = 0.5,
	legacyarial = 0.5,
	arial = 0.52,
	gothamssm = 0.58,
	buildersans = 0.52,
}

function Layout.fontInfo(r: any): (string, boolean, number)
	local face = P(r, "FontFace")
	local family = if face then tostring(face.Family) else ""
	local lower = string.lower(family)
	if string.find(lower, SILKSCREEN_ID, 1, true) then
		return "Silkscreen", true, WIDTH.silkscreen
	end
	local name = string.match(lower, "families/([%w_]+)%.json") or lower
	if name == "arcade" or name == "pressstart2p" then
		return "Arcade", true, WIDTH.arcade
	end
	local w = WIDTH[name] or 0.55
	return name, false, w
end

local function stripRich(text: string): string
	return (string.gsub(text, "<[^>]->", ""))
end

-- Returns width, height, line count of `text` at `size`, wrapped to wrapW.
function Layout.measure(text: string, size: number, wf: number, wrapW: number?): (number, number, number)
	if text == "" then
		return 0, 0, 0
	end
	local cw = size * wf
	local maxW, lines = 0, 0
	for para in string.gmatch(text .. "\n", "(.-)\n") do
		if not wrapW or wrapW <= 0 then
			lines += 1
			maxW = math.max(maxW, utf8.len(para) or #para) -- chars
		else
			local limit = math.max(1, math.floor(wrapW / cw))
			local cur = 0
			local any = false
			for word in string.gmatch(para, "%S+") do
				local len = utf8.len(word) or #word
				if cur == 0 then
					cur = len
				elseif cur + 1 + len <= limit then
					cur += 1 + len
				else
					lines += 1
					maxW = math.max(maxW, math.min(cur, limit))
					cur = len
				end
				while cur > limit do
					lines += 1
					maxW = math.max(maxW, limit)
					cur -= limit
				end
				any = true
			end
			lines += 1
			maxW = math.max(maxW, if any then cur else 0)
		end
	end
	return maxW * cw, lines * size, lines
end

function Layout.labelText(r: any): string
	local text = P(r, "Text") or ""
	if P(r, "RichText") then
		text = stripRich(text)
	end
	return text
end

local function padOf(r: any, w: number, h: number): (number, number, number, number)
	local pad = childOfClass(r, "UIPadding")
	if not pad then
		return 0, 0, 0, 0
	end
	local function u(prop: string, base: number): number
		local sc, of = U1(P(pad, prop))
		return sc * base + of
	end
	return u("PaddingLeft", w), u("PaddingTop", h), u("PaddingRight", w), u("PaddingBottom", h)
end

-- largest TextScaled size that fits the (unscaled) box
function Layout.scaledSize(r: any, w: number, h: number): number
	local text = Layout.labelText(r)
	local _, _, wf = Layout.fontInfo(r)
	local pl, pt, pr, pb = padOf(r, w, h)
	local bw, bh = w - pl - pr, h - pt - pb
	local lo, hi = 1, 100
	if bw <= 0 or bh <= 0 then
		hi = 1
	elseif text ~= "" then
		while lo < hi do
			local mid = math.ceil((lo + hi) / 2)
			local mw, mh = Layout.measure(text, mid, wf, bw)
			if mh <= bh + 0.01 and mw <= bw + 0.01 then
				lo = mid
			else
				hi = mid - 1
			end
		end
	else
		lo = math.max(1, math.floor(bh))
	end
	local size = lo
	local c = childOfClass(r, "UITextSizeConstraint")
	if c then
		size = math.clamp(size, P(c, "MinTextSize"), math.max(P(c, "MinTextSize"), P(c, "MaxTextSize")))
	end
	return size
end

-- text size in the object's own (unscaled) space
function Layout.textSize(r: any, w: number?, h: number?): number
	if P(r, "TextScaled") then
		local L = r.layout
		local bw = w or (L and L.lw) or 0
		local bh = h or (L and L.lh) or 0
		return Layout.scaledSize(r, bw, bh)
	end
	return P(r, "TextSize") or 14
end

function Layout.textBounds(r: any, w: number?, h: number?): (number, number)
	local text = Layout.labelText(r)
	local _, _, wf = Layout.fontInfo(r)
	local L = r.layout
	local bw = w or (L and L.lw)
	if bw == nil then
		local s = P(r, "Size")
		bw = s and s.X.Offset or 0
	end
	local bh = h or (L and L.lh) or 0
	local size = Layout.textSize(r, bw, bh)
	local pl, _, pr = padOf(r, bw, bh)
	local wrap = if (P(r, "TextWrapped") or P(r, "TextScaled")) then bw - pl - pr else nil
	local mw, mh = Layout.measure(text, size, wf, wrap)
	return mw, mh
end

-- Measure / arrange ----------------------------------------------------------

local function sizeConstraints(r: any, w: number, h: number): (number, number)
	local sc = childOfClass(r, "UISizeConstraint")
	if sc then
		local mnX, mnY = XY(P(sc, "MinSize"))
		local mxX, mxY = XY(P(sc, "MaxSize"))
		if mxX == 0 then
			mxX = math.huge
		end
		if mxY == 0 then
			mxY = math.huge
		end
		w = math.clamp(w, mnX, math.max(mnX, mxX))
		h = math.clamp(h, mnY, math.max(mnY, mxY))
	end
	local ar = childOfClass(r, "UIAspectRatioConstraint")
	if ar then
		local ratio = P(ar, "AspectRatio")
		if ratio and ratio > 0 then
			local atype = tostring(P(ar, "AspectType"))
			local axis = tostring(P(ar, "DominantAxis"))
			if string.find(atype, "ScaleWithParentSize", 1, true) then
				if string.find(axis, "Height", 1, true) then
					w = h * ratio
				else
					h = w / ratio
				end
			else
				if h > 0 and w / h > ratio then
					w = h * ratio
				else
					h = w / ratio
				end
			end
		end
	end
	return w, h
end

local function ownScale(r: any): number
	local s = childOfClass(r, "UIScale")
	return if s then (P(s, "Scale") or 1) else 1
end

local enumNames: { [any]: string } = {}
local function enumName(v: any): string
	if v == nil then
		return ""
	end
	local n = enumNames[v]
	if n == nil then
		n = string.match(tostring(v), "([%w_]+)$") or ""
		enumNames[v] = n
	end
	return n
end

local arrange: (r: any, w: number, h: number) -> (number, number)

-- base size of a child inside a content box of (bw, bh)
local function baseSize(cr: any, bw: number, bh: number): (number, number)
	local xs, xo, ys, yo = U2(P(cr, "Size"))
	local w = bw * xs + xo
	local h = bh * ys + yo
	return sizeConstraints(cr, w, h)
end

-- final size after AutomaticSize; lays out cr's subtree as a side effect
local function measureNode(cr: any, w: number, h: number): (number, number)
	local auto = enumName(P(cr, "AutomaticSize"))
	local isText = cr.impl.members.TextBounds ~= nil
	local ew, eh = arrange(cr, w, h)
	if auto ~= "None" and auto ~= "" then
		local nw, nh = w, h
		if isText then
			local pl, pt, pr, pb = padOf(cr, w, h)
			local wrapW = if auto == "Y" and (P(cr, "TextWrapped") or P(cr, "TextScaled")) then w - pl - pr else nil
			local _, _, wf = Layout.fontInfo(cr)
			local tw, th = Layout.measure(Layout.labelText(cr), P(cr, "TextSize") or 14, wf, wrapW)
			ew = math.max(ew, tw + pl + pr)
			eh = math.max(eh, th + pt + pb)
		end
		if auto == "X" or auto == "XY" then
			nw = math.max(w, ew)
		end
		if auto == "Y" or auto == "XY" then
			nh = math.max(h, eh)
		end
		nw, nh = sizeConstraints(cr, nw, nh)
		if nw ~= w or nh ~= h then
			arrange(cr, nw, nh)
		end
		return nw, nh
	end
	return w, h
end

-- Lays out the children of r (local size w x h). Returns content extents.
arrange = function(r: any, w: number, h: number): (number, number)
	-- memoised per pass: nested AutomaticSize containers would otherwise
	-- re-lay their subtrees exponentially often
	if r._arrPass == Layout.passId and r._arrW == w and r._arrH == h then
		return r._arrX, r._arrY
	end
	local ex, ey = Layout._arrange(r, w, h)
	r._arrPass, r._arrW, r._arrH, r._arrX, r._arrY = Layout.passId, w, h, ex, ey
	return ex, ey
end

Layout._arrange = function(r: any, w: number, h: number): (number, number)
	local pl, pt, pr, pb = padOf(r, w, h)
	local bx, by, bw, bh = pl, pt, math.max(0, w - pl - pr), math.max(0, h - pt - pb)
	local scroll = r.class == "ScrollingFrame"
	if scroll then
		local cxs, cxo, cys, cyo = U2(P(r, "CanvasSize"))
		local cw = bw * cxs + cxo
		local ch = bh * cys + cyo
		bw, bh = math.max(bw, cw), math.max(bh, ch)
	end
	local md = mods(r)
	local list, grid = md.UIListLayout, md.UIGridLayout
	local kids = table.clone(md.kids)
	local maxX, maxY = 0, 0
	local function place(cr: any, x: number, y: number, cw: number, ch: number)
		local s = ownScale(cr)
		cr.layout = cr.layout or {}
		local L = cr.layout
		L.lx, L.ly, L.lw, L.lh, L.s = x, y, cw, ch, s
		local apx, apy = XY(P(cr, "AnchorPoint"))
		-- extent of the scaled box in parent space (scaled about the anchor)
		local ax, ay = x + apx * cw, y + apy * ch
		local x0, y0 = ax - apx * cw * s, ay - apy * ch * s
		maxX = math.max(maxX, x0 + cw * s + pr)
		maxY = math.max(maxY, y0 + ch * s + pb)
	end
	local function sortKids()
		local byName = string.find(tostring(P(list or grid, "SortOrder")), "Name", 1, true) ~= nil
		table.sort(kids, function(a, b)
			if byName then
				return a.name < b.name
			end
			local la, lb = P(a, "LayoutOrder"), P(b, "LayoutOrder")
			if la == lb then
				return a.id < b.id
			end
			return la < lb
		end)
	end
	if list then
		sortKids()
		local horizontal = enumName(P(list, "FillDirection")) == "Horizontal"
		local pds, pdo = U1(P(list, "Padding"))
		local gap = pds * (if horizontal then bw else bh) + pdo
		local mainSize = if horizontal then bw else bh
		local crossSize = if horizontal then bh else bw
		local stretchAll = enumName(P(list, "ItemLineAlignment")) == "Stretch"
		local sizes = {}
		local total = 0
		local nvis = 0
		for i, cr in kids do
			local cw, ch = baseSize(cr, bw, bh)
			cw, ch = measureNode(cr, cw, ch)
			sizes[i] = { cw, ch }
			if P(cr, "Visible") ~= false then
				local s = ownScale(cr)
				total += (if horizontal then cw * s else ch * s) + (if nvis > 0 then gap else 0)
				nvis += 1
			end
		end
		-- flex (UIFlexItem / UIListLayout.HorizontalFlex|VerticalFlex) and stretch
		local flexAlign = enumName(P(list, if horizontal then "HorizontalFlex" else "VerticalFlex"))
		local remaining = mainSize - total
		local weights, totalW = {}, 0
		for i, cr in kids do
			local w = 0
			local fi = childOfClass(cr, "UIFlexItem")
			if P(cr, "Visible") ~= false then
				if fi then
					local mode = enumName(P(fi, "FlexMode"))
					if remaining >= 0 then
						w = if mode == "Fill" or mode == "Grow" then 1 elseif mode == "Custom" then (P(fi, "GrowRatio") or 0) else 0
					else
						w = if mode == "Fill" or mode == "Shrink" then 1 elseif mode == "Custom" then (P(fi, "ShrinkRatio") or 0) else 0
					end
				elseif flexAlign == "Fill" then
					w = 1
				end
			end
			weights[i] = w
			totalW += w
			local stretch = stretchAll or (fi ~= nil and enumName(P(fi, "ItemLineAlignment")) == "Stretch")
			if (totalW > 0 and w > 0 and remaining ~= 0) or stretch then
				local cw, ch = sizes[i][1], sizes[i][2]
				if stretch then
					if horizontal then
						ch = crossSize
					else
						cw = crossSize
					end
				end
				sizes[i] = { cw, ch, stretch }
			end
		end
		if totalW > 0 and remaining ~= 0 then
			for i, cr in kids do
				if weights[i] > 0 then
					local add = remaining * weights[i] / totalW
					if horizontal then
						sizes[i][1] = math.max(0, sizes[i][1] + add)
					else
						sizes[i][2] = math.max(0, sizes[i][2] + add)
					end
					sizes[i][3] = true
				end
			end
			total = mainSize
		end
		for i, cr in kids do
			if sizes[i][3] then
				arrange(cr, sizes[i][1], sizes[i][2])
			end
		end
		local extra = 0
		local leadGap = 0
		if totalW == 0 and nvis > 0 and remaining > 0 then
			if flexAlign == "SpaceBetween" and nvis > 1 then
				extra = remaining / (nvis - 1)
			elseif flexAlign == "SpaceAround" then
				extra = remaining / nvis
				leadGap = extra / 2
			elseif flexAlign == "SpaceEvenly" then
				extra = remaining / (nvis + 1)
				leadGap = extra
			end
			if extra > 0 then
				total = mainSize
			end
		end
		local ha = enumName(P(list, "HorizontalAlignment"))
		local va = enumName(P(list, "VerticalAlignment"))
		local cursor = 0
		if horizontal then
			cursor = if ha == "Center" then (bw - total) / 2 elseif ha == "Right" then bw - total else 0
		else
			cursor = if va == "Center" then (bh - total) / 2 elseif va == "Bottom" then bh - total else 0
		end
		cursor += leadGap
		for i, cr in kids do
			local cw, ch = sizes[i][1], sizes[i][2]
			local s = ownScale(cr)
			if P(cr, "Visible") == false then
				-- invisible children do not take space in a list layout
				place(cr, bx, by, cw, ch)
				continue
			end
			local x, y
			if horizontal then
				x = bx + cursor
				y = by + (if va == "Center" then (bh - ch * s) / 2 elseif va == "Bottom" then bh - ch * s else 0)
				cursor += cw * s + gap + extra
			else
				y = by + cursor
				x = bx + (if ha == "Center" then (bw - cw * s) / 2 elseif ha == "Right" then bw - cw * s else 0)
				cursor += ch * s + gap + extra
			end
			-- place() expects the unscaled top-left; list positions are of the scaled box
			local apx, apy = XY(P(cr, "AnchorPoint"))
			place(cr, x + apx * cw * (s - 1), y + apy * ch * (s - 1), cw, ch)
		end
	elseif grid then
		sortKids()
		local cxs, cxo, cys, cyo = U2(P(grid, "CellSize"))
		local pxs, pxo, pys, pyo = U2(P(grid, "CellPadding"))
		local cw = bw * cxs + cxo
		local ch = bh * cys + cyo
		local gx = bw * pxs + pxo
		local gy = bh * pys + pyo
		local cols = math.max(1, math.floor((bw + gx) / math.max(1, cw + gx)))
		local maxCells = P(grid, "FillDirectionMaxCells") or 0
		if maxCells > 0 then
			cols = math.min(cols, maxCells)
		end
		local i = 0
		for _, cr in kids do
			if P(cr, "Visible") == false then
				place(cr, bx, by, cw, ch)
				continue
			end
			local col, row = i % cols, i // cols
			measureNode(cr, cw, ch)
			place(cr, bx + col * (cw + gx), by + row * (ch + gy), cw, ch)
			i += 1
		end
	else
		for _, cr in kids do
			local cw, ch = baseSize(cr, bw, bh)
			cw, ch = measureNode(cr, cw, ch)
			local pxs, pxo, pys, pyo = U2(P(cr, "Position"))
			local apx, apy = XY(P(cr, "AnchorPoint"))
			local x = bx + bw * pxs + pxo - apx * cw
			local y = by + bh * pys + pyo - apy * ch
			place(cr, x, y, cw, ch)
		end
	end
	if scroll then
		r.layout = r.layout or {}
		r.layout.contentH = maxY
	end
	return maxX, maxY
end

-- Screen pass -----------------------------------------------------------------

local function intersect(a: any, b: any): any
	local x0, y0 = math.max(a[1], b[1]), math.max(a[2], b[2])
	local x1, y1 = math.min(a[3], b[3]), math.min(a[4], b[4])
	return { x0, y0, math.max(x0, x1), math.max(y0, y1) }
end

local changedList: { any } = {}

local function setAbs(r: any, x: number, y: number, w: number, h: number, inset: number)
	local L = r.layout
	local px, py, pw, ph = L.x, L.y, L.w, L.h
	L.x, L.y, L.w, L.h = x, y, w, h
	L.inset = inset
	if px ~= nil then
		if math.abs(pw - w) > 0.01 or math.abs(ph - h) > 0.01 then
			table.insert(changedList, { r, "AbsoluteSize" })
		end
		if math.abs(px - x) > 0.01 or math.abs(py - y) > 0.01 then
			table.insert(changedList, { r, "AbsolutePosition" })
		end
	elseif w ~= 0 or h ~= 0 then
		table.insert(changedList, { r, "AbsoluteSize" })
		table.insert(changedList, { r, "AbsolutePosition" })
	end
end

local function screenPass(r: any, ox: number, oy: number, k: number, clip: any, vis: boolean, inset: number, zbase: number)
	for _, c in r.children do
		local cr = recs[c]
		local L = cr.layout
		if L and L.lx ~= nil and isA(cr, "GuiObject") then
			local s = L.s or 1
			local apx, apy = XY(P(cr, "AnchorPoint"))
			local ax = ox + k * (L.lx + apx * L.lw)
			local ay = oy + k * (L.ly + apy * L.lh)
			local kk = k * s
			local sx, sy = ax - apx * L.lw * kk, ay - apy * L.lh * kk
			local sw, sh = L.lw * kk, L.lh * kk
			setAbs(cr, sx, sy, sw, sh, inset)
			L.k = kk
			L.visible = vis and P(cr, "Visible") == true
			L.clip = clip
			L.z = zbase
			local childClip = clip
			if cr.class == "ScrollingFrame" or P(cr, "ClipsDescendants") then
				childClip = intersect(clip, { sx, sy, sx + sw, sy + sh })
			end
			local cox, coy = sx, sy
			if cr.class == "ScrollingFrame" then
				local cpx, cpy = XY(P(cr, "CanvasPosition"))
				local cxs, cxo, cys, cyo = U2(P(cr, "CanvasSize"))
				local canvasH = math.max(L.lh, L.lh * cys + cyo, L.contentH or 0)
				local canvasW = math.max(L.lw, L.lw * cxs + cxo)
				local cx = math.clamp(cpx, 0, math.max(0, canvasW - L.lw))
				local cy = math.clamp(cpy, 0, math.max(0, canvasH - L.lh))
				cox -= cx * kk
				coy -= cy * kk
			end
			screenPass(cr, cox, coy, kk, childClip, L.visible, inset, zbase)
		elseif cr.layout then
			cr.layout.visible = false
		end
	end
end

function Layout.layoutScreenGui(r: any)
	Layout.passId += 1
	local vw, vh = Layout.viewport.w, Layout.viewport.h
	local ignore = P(r, "IgnoreGuiInset")
	local inset = if ignore then 0 else Layout.TOP_INSET
	r.layout = r.layout or {}
	local k = ownScale(r)
	local w, h = vw, vh - inset
	r.layout.lw, r.layout.lh = w, h
	setAbs(r, 0, inset, w, h, inset)
	r.layout.visible = P(r, "Enabled") == true
	r.layout.k = 1
	arrange(r, w, h)
	screenPass(r, 0, inset, k, { 0, 0, vw, vh }, r.layout.visible, inset, P(r, "DisplayOrder") or 0)
end

-- Lays out every ScreenGui under the PlayerGui; fires AbsoluteSize /
-- AbsolutePosition change signals for objects that moved or resized.
function Layout.pass(playerGui: any): number
	table.clear(changedList)
	local pg = recs[playerGui]
	for _, c in pg.children do
		local cr = recs[c]
		if cr.class == "ScreenGui" and (cr.layoutDirty or not cr.layout or Layout.forceAll) then
			cr.layoutDirty = false
			Layout.layoutScreenGui(cr)
		end
	end
	Layout.forceAll = false
	local n = #changedList
	for _, ch in changedList do
		Rt.changed(ch[1], ch[2])
	end
	return n
end

function Layout.absSize(r: any): any
	local L = r.layout
	if L and L.w then
		return V2.new(L.w, L.h)
	end
	return V2.zero
end

function Layout.absPos(r: any): any
	local L = r.layout
	if L and L.x then
		return V2.new(L.x, L.y - Layout.TOP_INSET)
	end
	return V2.zero
end

return Layout
