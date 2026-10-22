--!strict
-- Mood: a restrained night grade. Warm practical light inside, cold pale fog
-- kept outside the glass, rain in the alley and on the windows, a little film
-- grain, ambient loops, phone glows and eye adaptation during blackouts, the
-- blinking door indicator and a gradual "dread" shift as more data is erased.
-- Everything here is cosmetic and client-local. Server-driven light state
-- (Enabled, fixture material and colour) is never written; flickers only
-- scale light brightness and a local fade, then restore, so nothing sticks.
--
-- Palette (docs/ART_DIRECTION.md): outdoor fog #A8BAC3, cold ambient #778B96,
-- shadow floor #353F46, carpet/curtains #60494D, cream trim #B7B09C, amber
-- practicals #C8A66B.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local AssetService = game:GetService("AssetService")

local Layout = require(ReplicatedStorage.Shared.Layout)
local Fonts = require(ReplicatedStorage.Shared.Fonts)
local ArtController = require(script.Parent.ArtController)
local State = require(script.Parent.State)
local Sfx = require(script.Parent.Parent.Ui.Sfx)

local player = Players.LocalPlayer

local Atmosphere = {}

local FOG = Color3.fromRGB(168, 186, 195) -- #A8BAC3
local SLATE = Color3.fromRGB(119, 139, 150) -- #778B96
local CHARCOAL = Color3.fromRGB(53, 63, 70) -- #353F46
local PHONE = Color3.fromRGB(190, 205, 220)
local PHOSPHOR = Color3.fromRGB(150, 220, 160)
local WINDOW_LIGHT = Color3.fromRGB(150, 168, 180) -- moonlit street through the glass

-- Every number the art direction cares about lives here.
local GRADE = {
	-- ColorCorrection: muted, never crushed (the small lift offsets the contrast)
	saturation = -0.16,
	contrast = 0.04,
	brightness = 0.015,
	tintWarm = Color3.fromRGB(254, 251, 246), -- near neutral: warmth comes from the practicals
	tintCold = Color3.fromRGB(234, 240, 246),
	-- Bloom: only true highlights (neon, bulbs) glow, and only a little
	bloomIntensity = 0.22,
	bloomSize = 20,
	bloomThreshold = 2,
	-- Atmosphere is global, so it stays thin enough that the 45-stud interior
	-- shows no haze; the visible fog outside comes from the exterior fog cards.
	density = 0.2,
	haze = 1,
	decay = Color3.fromRGB(98, 112, 122),
	-- Lighting: charcoal shadow floor inside, slate outside, a dim moon
	ambient = CHARCOAL,
	outdoorAmbient = SLATE,
	sun = 0.25,
	-- dread (0..1 server attribute) at full strength: colder, a touch greyer,
	-- denser fog outside, almost none added indoors
	dreadSaturation = -0.1,
	dreadDensity = 0.04,
	dreadFog = 0.45,
	-- blackout (LightsOn == false): a moment of real darkness, then the eyes
	-- adapt; ambient never drops below ~40/255 per channel
	blackoutAmbient = Color3.fromRGB(44, 52, 59),
	blackoutSaturation = -0.06,
	blackoutCold = 0.35,
	blackoutExposure = 0.2,
	adaptDelay = 1.5,
}

-- Phone glow carried by every character: a faint fill normally, a usable
-- light in a blackout. Teammates' phones only show in the dark.
local GLOW = { idle = 0.15, idleRange = 8, dark = 0.42, darkRange = 12, mate = 0.28, mateRange = 9 }

local FLICKER_RADIUS = 20
local FIXTURE_NAMES: { [string]: boolean } = { Fluorescent = true, Bulb = true }

local cc: ColorCorrectionEffect
local bloom: BloomEffect
local atmos: Atmosphere
local rainEmitters: { ParticleEmitter } = {}
local tense: Sound? = nil
local dread = 0
local blackout = false
local blackoutSince = 0
local flickerDip = 0

Atmosphere.cc = function(): ColorCorrectionEffect
	return cc
end

-- Surfaces -------------------------------------------------------------------

-- Final albedo after texture modulation. A Texture's Color3 can only darken,
-- so when a texture is darker than its target the part colour underneath is
-- let through (Texture.Transparency, at most `wash`). Surfaces not listed
-- settle on their part's own colour, so any texture only adds detail. When a
-- target is out of reach, interior surfaces keep their brightness and
-- `keepHue` surfaces darken instead of drifting toward the texture's colour.
-- Keep the names in sync with MapBuilder's `surface` options.
type SurfaceSpec = { target: Color3?, wash: number, keepHue: boolean? }
local SURFACES: { [string]: SurfaceSpec } = {
	wall_office = { target = Color3.fromRGB(216, 211, 199), wash = 0.6 }, -- light painted plaster
	wall_kitchen = { target = Color3.fromRGB(210, 211, 202), wash = 0.6 },
	carpet = { target = Color3.fromRGB(96, 73, 77), wash = 0.3 }, -- dusty burgundy #60494D
	ceiling_tile = { target = Color3.fromRGB(200, 200, 196), wash = 0.85 }, -- clean light grey
	brick_alley = { wash = 0.6, keepHue = true }, -- no mossy green outside
	floor_concrete = { wash = 0.6, keepHue = true },
}
local DEFAULT_WASH = 0.6

local surfaceMeans: { [string]: Vector3 } = {}

local function rgb(c: Color3): Vector3
	return Vector3.new(c.R, c.G, c.B) * 255
end

local function textureMean(name: string, img: EditableImage): Vector3
	local cached = surfaceMeans[name]
	if cached then
		return cached
	end
	local mean = Vector3.new(200, 200, 200)
	local size = img.Size
	local ok, buf = pcall(function()
		return img:ReadPixelsBuffer(Vector2.zero, size)
	end)
	if ok then
		local px = buf :: buffer
		local r, g, b, n = 0, 0, 0, 0
		for i = 0, size.X * size.Y - 1, 3 do
			local o = i * 4
			r += buffer.readu8(px, o)
			g += buffer.readu8(px, o + 1)
			b += buffer.readu8(px, o + 2)
			n += 1
		end
		if n > 0 then
			mean = Vector3.new(r / n, g / n, b / n)
		end
	end
	surfaceMeans[name] = mean
	return mean
end

-- Smallest wash that reaches the target (or gets closest), then the tint.
local function solveSurface(mean: Vector3, partColor: Vector3, goal: Vector3, minWash: number, maxWash: number, keepHue: boolean?): (number, Color3)
	local best, bestErr = minWash, math.huge
	local t = minWash
	while t <= maxWash + 1e-6 do
		local reach = mean * (1 - t) + partColor * t
		local err = math.max(goal.X - reach.X, 0) + math.max(goal.Y - reach.Y, 0) + math.max(goal.Z - reach.Z, 0)
		if err < bestErr - 0.5 then
			best, bestErr = t, err
		end
		if err <= 0.5 then
			break
		end
		t += 0.05
	end
	local target = goal
	if keepHue then
		local reach = mean * (1 - best) + partColor * best
		local s = math.min(1, reach.X / math.max(goal.X, 1), reach.Y / math.max(goal.Y, 1), reach.Z / math.max(goal.Z, 1))
		target = goal * s
	end
	local function k(want: number, m: number, p: number): number
		return math.clamp((want - best * p) / math.max((1 - best) * m, 1), 0, 1)
	end
	return best, Color3.new(k(target.X, mean.X, partColor.X), k(target.Y, mean.Y, partColor.Y), k(target.Z, mean.Z, partColor.Z))
end

local function applySurfaces()
	local function apply(t: Instance)
		if not t:IsA("Texture") then
			return
		end
		local name = t:GetAttribute("Surface")
		if typeof(name) ~= "string" then
			return
		end
		local img = ArtController.getSurface(name)
		if not img then
			return
		end
		t.ColorMapContent = Content.fromObject(img)
		local holder = t.Parent
		if not (holder and holder:IsA("BasePart")) then
			return
		end
		local spec = SURFACES[name]
		local target = if spec and spec.target then spec.target else holder.Color
		local wash, tint = solveSurface(textureMean(name, img), rgb(holder.Color), rgb(target), t.Transparency, if spec then spec.wash else DEFAULT_WASH, spec and spec.keepHue)
		t.Transparency = wash
		t.Color3 = tint
	end
	for _, t in CollectionService:GetTagged("Surface") do
		apply(t)
	end
	CollectionService:GetInstanceAddedSignal("Surface"):Connect(apply)
end

-- Exterior fog -----------------------------------------------------------------

-- Atmosphere fog is global and cannot tell inside from outside, so the cold
-- fog seen through the windows, down the alley and on the front street is a
-- few soft, slowly drifting cards placed only outside the building. They are
-- lit by the scene (street lamps glow in them), never collide, never block
-- raycasts and cast no shadows.
local FOG_W, FOG_H = 128, 64
local FOG_BASE = -1.2 -- card bottoms sit under the ground so their soft edge is hidden
local FOG_STEP = 1 / 15
local FOG_GAIN = 1 -- one knob for every card's opacity when tuning in Studio
type LayerSpec = { tile: number, speed: number }
local FOG_LAYERS: { LayerSpec } = { { tile = 34, speed = 0.45 }, { tile = 53, speed = -0.28 } }
-- the open street north of the office, seen through the windows
local NORTH_STREET = { minX = Layout.MAIN.minX - 12, maxX = Layout.MAIN.maxX + 14, minZ = Layout.MAIN.minZ - 16, maxZ = Layout.MAIN.minZ - 1 }

type FogLayer = { tex: Texture, tile: number, speed: number, phase: number }
type FogCard = { layers: { FogLayer }, opacity: number }
type Octave = { cx: number, cy: number, w: number, grid: { number } }

local fogCards: { FogCard } = {}
local fogLevel = 0

local function smooth(e0: number, e1: number, x: number): number
	local t = math.clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end

-- Periodic value noise: wraps horizontally so a card tiles seamlessly.
local function noise(o: Octave, u: number, v: number): number
	local x, y = u * o.cx, v * o.cy
	local x0, y0 = math.floor(x), math.floor(y)
	local fx, fy = x - x0, y - y0
	fx = fx * fx * (3 - 2 * fx)
	fy = fy * fy * (3 - 2 * fy)
	local x1 = (x0 + 1) % o.cx
	local y1 = math.min(y0 + 1, o.cy)
	local g, w = o.grid, o.cx
	local a = g[y0 * w + x0 + 1] + (g[y0 * w + x1 + 1] - g[y0 * w + x0 + 1]) * fx
	local b = g[y1 * w + x0 + 1] + (g[y1 * w + x1 + 1] - g[y1 * w + x0 + 1]) * fx
	return a + (b - a) * fy
end

-- White wisps with alpha: clear at the top, dense near the ground, a ragged
-- upper edge. Top and bottom rows stay transparent so tiling never seams.
-- `patch` also fades both ends, for a single sheet that must not tile.
local function fogImage(patch: boolean): EditableImage?
	local rng = Random.new(1931)
	local octaves: { Octave } = {}
	for i, spec in { { 4, 2, 0.55 }, { 8, 4, 0.3 }, { 16, 8, 0.15 } } do
		local cx, cy = spec[1], spec[2]
		local grid = table.create(cx * (cy + 1), 0)
		for j = 1, #grid do
			grid[j] = rng:NextNumber()
		end
		octaves[i] = { cx = cx, cy = cy, w = spec[3], grid = grid }
	end
	local buf = buffer.create(FOG_W * FOG_H * 4)
	for y = 0, FOG_H - 1 do
		local v = y / (FOG_H - 1)
		for x = 0, FOG_W - 1 do
			local u = x / FOG_W
			local n = 0
			for _, o in octaves do
				n += o.w * noise(o, u, v)
			end
			local body = smooth(0.04, 0.8, v + (n - 0.5) * 0.3) * (1 - smooth(0.93, 1, v))
			if patch then
				body *= smooth(0, 0.22, u) * smooth(0, 0.22, 1 - u)
			end
			local o = (y * FOG_W + x) * 4
			buffer.writeu8(buf, o, 255)
			buffer.writeu8(buf, o + 1, 255)
			buffer.writeu8(buf, o + 2, 255)
			buffer.writeu8(buf, o + 3, math.floor(body * (0.45 + 0.55 * n) * 255 + 0.5))
		end
	end
	local ok, img = pcall(function()
		local image = AssetService:CreateEditableImage({ Size = Vector2.new(FOG_W, FOG_H) })
		image:WritePixelsBuffer(Vector2.zero, Vector2.new(FOG_W, FOG_H), buf)
		return image
	end)
	return if ok then img :: EditableImage else nil
end

-- One card: a vertical sheet centred on (x, z), `width` along the axis that
-- `face` does not point down, its textured side facing `face`. Wide cards
-- tile and drift; a patch (low mist between props) is one still sheet.
type FogImages = { tiled: EditableImage, patch: EditableImage }
local function fogCard(folder: Folder, images: FogImages, rng: Random, x: number, z: number, width: number, height: number, face: Enum.NormalId, opacity: number, patch: boolean?)
	local alongX = face == Enum.NormalId.Front or face == Enum.NormalId.Back
	local p = Instance.new("Part")
	p.Name = "FogCard"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.AudioCanCollide = false
	p.CastShadow = false
	p.Transparency = 1
	p.Material = Enum.Material.SmoothPlastic
	p.Size = if alongX then Vector3.new(width, height, 0.05) else Vector3.new(0.05, height, width)
	p.CFrame = CFrame.new(x, FOG_BASE + height / 2, z)
	local card: FogCard = { layers = {}, opacity = opacity }
	local specs: { LayerSpec } = if patch then { { tile = width, speed = 0 } } else FOG_LAYERS
	for _, spec in specs do
		local t = Instance.new("Texture")
		t.Face = face
		t.ColorMapContent = Content.fromObject(if patch then images.patch else images.tiled)
		t.Color3 = FOG
		t.StudsPerTileU = spec.tile
		t.StudsPerTileV = height
		t.Transparency = 1
		t.Parent = p
		table.insert(card.layers, { tex = t, tile = spec.tile, speed = spec.speed, phase = if patch then 0 else rng:NextNumber() * spec.tile })
	end
	p.Parent = folder
	table.insert(fogCards, card)
end

local function buildExteriorFog()
	local tiled, patch = fogImage(false), fogImage(true)
	if not (tiled and patch) then
		return
	end
	local img: FogImages = { tiled = tiled, patch = patch }
	local folder = Instance.new("Folder")
	folder.Name = "ExteriorFog"
	local rng = Random.new(77)
	local Back, Front, Left, Right = Enum.NormalId.Back, Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right
	local N, A, S, K = NORTH_STREET, Layout.ALLEY, Layout.STREET, Layout.KITCHEN

	-- north street, through the office windows: the strip in front of the first
	-- card stays clear (missing-crew silhouettes stand there), the facade across
	-- fades behind the last
	local nx, nw = (N.minX + N.maxX) / 2, N.maxX - N.minX
	fogCard(folder, img, rng, nx, N.minZ + 4.4, nw, 16, Back, 0.3) -- just behind the street lamp
	fogCard(folder, img, rng, nx, N.minZ + 2.4, nw, 18, Back, 0.42)
	fogCard(folder, img, rng, nx, N.minZ + 0.5, nw, 22, Back, 0.4)

	-- alley: knee-high mist patches in the open middle lane (props line both
	-- walls), then deepening layers past the mouth so the figure emerges from
	-- fog but stands clear where it stops
	local az, aw = (A.minZ + A.maxZ) / 2, A.maxZ - A.minZ
	local lane, laneW = A.minZ + 8, 9 -- z -2.5 .. 6.5
	for _, dx in { 5.5, 14, 22 } do
		fogCard(folder, img, rng, A.minX + dx, lane, laneW, 3.4, Left, 0.4, true)
	end
	fogCard(folder, img, rng, A.maxX + 0.25, az, aw, 15, Left, 0.3) -- inside the alley limit
	fogCard(folder, img, rng, A.maxX + 5, az, aw, 15, Left, 0.45)
	fogCard(folder, img, rng, A.maxX + 11, az, aw, 15, Left, 0.55)
	fogCard(folder, img, rng, A.maxX + 15.4, az, aw, 15, Left, 0.6) -- in front of the back wall

	-- front street (the escape): fog closes the three open sides, low mist on the road
	local sx, sz = (S.minX + S.maxX) / 2, (S.minZ + S.maxZ) / 2 + 1
	fogCard(folder, img, rng, sx, S.maxZ + 0.5, S.maxX - S.minX + 8, 16, Front, 0.5)
	fogCard(folder, img, rng, S.minX - 0.5, sz, S.maxZ - S.minZ, 16, Right, 0.55)
	fogCard(folder, img, rng, S.maxX + 0.75, sz, S.maxZ - S.minZ, 16, Left, 0.55)
	fogCard(folder, img, rng, sx, S.minZ + 6, S.maxX - S.minX, 3, Front, 0.35, true)

	-- outside the frosted kitchen window there is only fog
	fogCard(folder, img, rng, K.minX - 2.5, (K.minZ + K.maxZ) / 2, K.maxZ - K.minZ + 4, 12, Right, 0.7)

	folder.Parent = workspace

	local acc, clock = 0, 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < FOG_STEP then
			return
		end
		clock += acc
		fogLevel += (dread - fogLevel) * (1 - math.exp(-acc / 4))
		for _, card in fogCards do
			local opacity = math.min(card.opacity * FOG_GAIN * (1 + GRADE.dreadFog * fogLevel), 0.9)
			local each = (1 - opacity) ^ (1 / #card.layers) -- the layers together reach `opacity`
			for _, layer in card.layers do
				layer.tex.OffsetStudsU = (layer.phase + clock * layer.speed) % layer.tile
				layer.tex.Transparency = each
			end
		end
		acc = 0
	end)
end

-- Cold light falling in through the north windows (stays on in a blackout).
local function windowLight()
	local M = Layout.MAIN
	local folder = Instance.new("Folder")
	folder.Name = "WindowLight"
	for _, x in Layout.WINDOWS_X do
		local p = Instance.new("Part")
		p.Name = "WindowSpill"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.AudioCanCollide = false
		p.CastShadow = false
		p.Transparency = 1
		p.Size = Vector3.new(5.6, 4, 0.05)
		p.CFrame = CFrame.new(x, 5.45, M.minZ - 0.3)
		local l = Instance.new("SurfaceLight")
		l.Face = Enum.NormalId.Back
		l.Color = WINDOW_LIGHT
		l.Brightness = 0.3
		l.Range = 10
		l.Angle = 70
		l.Shadows = true
		l.Parent = p
		p.Parent = folder
	end
	folder.Parent = workspace
end

-- Rain -------------------------------------------------------------------------

local function makeRain(region: { minX: number, maxX: number, minZ: number, maxZ: number }, height: number): ParticleEmitter
	local p = Instance.new("Part")
	p.Name = "RainCloud"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.new(region.maxX - region.minX, 1, region.maxZ - region.minZ)
	p.Position = Vector3.new((region.minX + region.maxX) / 2, height, (region.minZ + region.maxZ) / 2)
	p.Parent = workspace
	local e = Instance.new("ParticleEmitter")
	e.Rate = 220
	e.Lifetime = NumberRange.new(0.9, 1.1)
	e.Speed = NumberRange.new(55, 65)
	e.EmissionDirection = Enum.NormalId.Bottom
	e.SpreadAngle = Vector2.new(4, 4)
	e.Size = NumberSequence.new(0.06)
	e.Squash = NumberSequence.new(-3.5)
	e.Transparency = NumberSequence.new(0.6)
	e.LightEmission = 0.1
	e.LightInfluence = 0.7
	e.Color = ColorSequence.new(FOG)
	e.Orientation = Enum.ParticleOrientation.FacingCameraWorldUp
	e.Parent = p
	table.insert(rainEmitters, e)
	return e
end

local function rainOnGlass()
	-- slow drips sliding down each window (client-only frames)
	local drips: { { f: Frame, speed: number } } = {}
	for _, part in workspace:GetDescendants() do
		if part:IsA("BasePart") and part:GetAttribute("RainGlass") == true then
			local sg = Instance.new("SurfaceGui")
			sg.Face = Enum.NormalId.Back
			sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
			sg.PixelsPerStud = 30
			sg.LightInfluence = 1
			sg.Parent = part
			for _ = 1, 14 do
				local f = Instance.new("Frame")
				f.BorderSizePixel = 0
				f.BackgroundColor3 = Color3.fromRGB(184, 198, 206)
				f.BackgroundTransparency = 0.6 + math.random() * 0.3
				f.Size = UDim2.fromOffset(2, math.random(6, 18))
				f.Position = UDim2.fromScale(math.random(), math.random())
				f.Parent = sg
				table.insert(drips, { f = f, speed = 0.03 + math.random() * 0.08 })
			end
		end
	end
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.1 then
			return
		end
		for _, d in drips do
			local p = d.f.Position
			local y = p.Y.Scale + d.speed * acc
			if y > 1.05 then
				y = -0.05
			end
			d.f.Position = UDim2.fromScale(p.X.Scale, y)
		end
		acc = 0
	end)
end

local function buildGrain()
	local gui = Instance.new("ScreenGui")
	gui.Name = "Grain"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 15
	gui.Parent = player:WaitForChild("PlayerGui")
	local images: { EditableImage } = {}
	local ok = pcall(function()
		for _ = 1, 3 do
			local img = AssetService:CreateEditableImage({ Size = Vector2.new(96, 96) })
			local buf = buffer.create(96 * 96 * 4)
			for i = 0, 96 * 96 - 1 do
				local v = math.random(0, 255)
				buffer.writeu8(buf, i * 4, v)
				buffer.writeu8(buf, i * 4 + 1, v)
				buffer.writeu8(buf, i * 4 + 2, v)
				buffer.writeu8(buf, i * 4 + 3, 255)
			end
			img:WritePixelsBuffer(Vector2.zero, Vector2.new(96, 96), buf)
			table.insert(images, img)
		end
	end)
	if not ok or #images == 0 then
		return
	end
	local label = Instance.new("ImageLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.ImageContent = Content.fromObject(images[1])
	label.ScaleType = Enum.ScaleType.Tile
	label.TileSize = UDim2.fromOffset(192, 192)
	label.ImageTransparency = 0.96
	label.Active = false
	label.Interactable = false
	label.Parent = gui
	local i = 1
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc > 0.06 then
			acc = 0
			i = i % #images + 1
			label.ImageContent = Content.fromObject(images[i])
			label.Position = UDim2.fromOffset(math.random(-40, 0), math.random(-40, 0))
			label.ImageTransparency = 0.96 - dread * 0.015
		end
	end)
end

-- Grade --------------------------------------------------------------------------

local function setupLighting()
	-- one grade only: disable post effects a saved place may already carry
	for _, e in Lighting:GetChildren() do
		if e:IsA("PostEffect") then
			e.Enabled = false
		end
	end
	cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "NightGrade"
	cc.Saturation = GRADE.saturation
	cc.Contrast = GRADE.contrast
	cc.Brightness = GRADE.brightness
	cc.TintColor = GRADE.tintWarm
	cc.Parent = Lighting
	bloom = Instance.new("BloomEffect")
	bloom.Name = "SoftBloom"
	bloom.Intensity = GRADE.bloomIntensity
	bloom.Size = GRADE.bloomSize
	bloom.Threshold = GRADE.bloomThreshold
	bloom.Parent = Lighting
	local existing = Lighting:FindFirstChildOfClass("Atmosphere")
	atmos = existing or Instance.new("Atmosphere")
	atmos.Density = GRADE.density
	atmos.Offset = 0
	atmos.Color = FOG
	atmos.Decay = GRADE.decay
	atmos.Glare = 0
	atmos.Haze = GRADE.haze
	atmos.Parent = Lighting
	Lighting.ClockTime = 1.5
	Lighting.Brightness = GRADE.sun
	Lighting.Ambient = GRADE.ambient
	Lighting.OutdoorAmbient = GRADE.outdoorAmbient
	Lighting.EnvironmentDiffuseScale = 0.2
	Lighting.EnvironmentSpecularScale = 0.2
	Lighting.ExposureCompensation = 0
end

-- A soft colour cast that eases in and fades out (never a hard flash).
type Sting = { color: Color3, t0: number, attack: number, release: number }
local sting: Sting? = nil

function Atmosphere.sting(color: Color3, seconds: number)
	sting = { color = color, t0 = os.clock(), attack = 0.35, release = math.max(seconds, 0.5) }
end

local function stingWeight(s: Sting, now: number): number
	local t = now - s.t0
	if t < s.attack then
		return math.sin(t / s.attack * math.pi / 2)
	end
	local r = 1 - (t - s.attack) / s.release
	return if r > 0 then r * r else 0
end

type Grade = { tint: Color3, sat: number, bright: number, ambient: Color3, exposure: number, density: number }
local cur: Grade = {
	tint = GRADE.tintWarm,
	sat = GRADE.saturation,
	bright = GRADE.brightness,
	ambient = GRADE.ambient,
	exposure = 0,
	density = GRADE.density,
}

local want: Grade = table.clone(cur)

-- Fills `want` (reused every frame) with the grade the current state asks for.
local function wanted(now: number)
	local cold = math.clamp(dread + (if blackout then GRADE.blackoutCold else 0), 0, 1)
	local tint = GRADE.tintWarm:Lerp(GRADE.tintCold, cold)
	local s = sting
	if s then
		local w = stingWeight(s, now)
		if w <= 0 and now - s.t0 > s.attack then
			sting = nil
		else
			tint = tint:Lerp(s.color, w)
		end
	end
	local adapted = blackout and now - blackoutSince > GRADE.adaptDelay
	want.tint = tint
	want.sat = GRADE.saturation + GRADE.dreadSaturation * dread + (if blackout then GRADE.blackoutSaturation else 0)
	want.bright = GRADE.brightness - flickerDip
	want.ambient = if blackout then GRADE.blackoutAmbient else GRADE.ambient
	want.exposure = if adapted then GRADE.blackoutExposure else 0
	want.density = GRADE.density + GRADE.dreadDensity * dread
end

local function colorGap(a: Color3, b: Color3): number
	return math.abs(a.R - b.R) + math.abs(a.G - b.G) + math.abs(a.B - b.B)
end

local function gradeStep(dt: number)
	wanted(os.clock())
	local gap = colorGap(cur.tint, want.tint)
		+ colorGap(cur.ambient, want.ambient)
		+ math.abs(cur.sat - want.sat)
		+ math.abs(cur.bright - want.bright)
		+ math.abs(cur.exposure - want.exposure)
		+ math.abs(cur.density - want.density)
	if gap < 1e-4 then
		return
	end
	local function k(tau: number): number
		return 1 - math.exp(-dt / tau)
	end
	cur.tint = cur.tint:Lerp(want.tint, k(0.15))
	cur.sat += (want.sat - cur.sat) * k(0.6)
	cur.bright += (want.bright - cur.bright) * k(0.05)
	cur.ambient = cur.ambient:Lerp(want.ambient, k(0.5))
	cur.exposure += (want.exposure - cur.exposure) * k(if blackout then 2.5 else 0.6)
	cur.density += (want.density - cur.density) * k(3)
	cc.TintColor = cur.tint
	cc.Saturation = cur.sat
	cc.Brightness = cur.bright
	Lighting.Ambient = cur.ambient
	Lighting.ExposureCompensation = cur.exposure
	atmos.Density = cur.density
end

local function updateDread()
	local v = workspace:GetAttribute("Dread")
	dread = if typeof(v) == "number" then math.clamp(v, 0, 1) else 0
	-- rain picks up and the tense loop rises as the purge nears
	for _, e in rainEmitters do
		e.Rate = 220 + dread * 200
	end
	if tense then
		tense.Volume = 0.05 + dread * 0.3
	end
end

local function updatePower()
	local dark = workspace:GetAttribute("LightsOn") == false
	if dark and not blackout then
		blackoutSince = os.clock()
	end
	blackout = dark
end

-- Phone glows ------------------------------------------------------------------

type Glow = { light: PointLight, own: boolean }
local glows: { Glow } = {}

local function addGlow(plr: Player, character: Model)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not (root and root:IsA("BasePart")) then
		return
	end
	local own = plr == player
	local att = Instance.new("Attachment")
	att.Name = "PhoneGlow"
	att.Position = Vector3.new(0, 1, -1.2) -- held in front of the chest
	local l = Instance.new("PointLight")
	l.Name = "PhoneGlow"
	l.Color = PHONE
	l.Shadows = false
	l.Range = if own then GLOW.idleRange else GLOW.mateRange
	l.Brightness = if own then GLOW.idle else 0
	l.Enabled = own
	l.Parent = att
	att.Parent = root
	table.insert(glows, { light = l, own = own })
end

local function watchPlayer(plr: Player)
	plr.CharacterAdded:Connect(function(character)
		addGlow(plr, character)
	end)
	if plr.Character then
		task.spawn(addGlow, plr, plr.Character)
	end
end

local function glowStep(dt: number)
	local k = 1 - math.exp(-dt / 0.6)
	for i = #glows, 1, -1 do
		local g = glows[i]
		local l = g.light
		if not l:IsDescendantOf(workspace) then
			table.remove(glows, i)
			continue
		end
		local b = if g.own then (if blackout then GLOW.dark else GLOW.idle) else (if blackout then GLOW.mate else 0)
		local r = if g.own then (if blackout then GLOW.darkRange else GLOW.idleRange) else GLOW.mateRange
		if math.abs(l.Brightness - b) > 0.002 or math.abs(l.Range - r) > 0.02 then
			l.Brightness += (b - l.Brightness) * k
			l.Range += (r - l.Range) * k
		end
		local on = g.own or blackout or l.Brightness > 0.01
		if l.Enabled ~= on then
			l.Enabled = on
		end
	end
end

-- Fixture flicker ----------------------------------------------------------------

-- Power warnings and disturbances dim the real ceiling fixtures for a moment
-- (light brightness plus a local fade of the neon panel). Dips last 0.08-0.18 s
-- with at least 0.26 s lit in between, so never more than 3 flashes a second.
type FixtureLight = { light: Light, base: number }
type Fixture = { part: BasePart, lights: { FixtureLight } }
local fixtures: { Fixture } = {}
local flickerToken = 0
local flickering = false

local function collectFixtures()
	table.clear(fixtures)
	local map = workspace:FindFirstChild("Map")
	local folder = map and map:FindFirstChild("Lights")
	if not folder then
		return
	end
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") and FIXTURE_NAMES[d.Name] then
			local lights: { FixtureLight } = {}
			for _, c in d:GetChildren() do
				if c:IsA("Light") then
					table.insert(lights, { light = c, base = c.Brightness })
				end
			end
			if #lights > 0 then
				table.insert(fixtures, { part = d, lights = lights })
			end
		end
	end
end

local function setLevel(list: { Fixture }, level: number)
	local lit = workspace:GetAttribute("LightsOn") ~= false
	for _, f in list do
		f.part.LocalTransparencyModifier = if lit then (1 - level) * 0.7 else 0
		for _, fl in f.lights do
			fl.light.Brightness = fl.base * level
		end
	end
end

-- `near`: only fixtures around that point flicker; otherwise the whole building.
function Atmosphere.flicker(seconds: number, strength: number?, near: Vector3?)
	local s = math.clamp(strength or 0.35, 0.05, 1)
	if #fixtures == 0 then
		collectFixtures()
	end
	flickerToken += 1
	local token = flickerToken
	if flickering then
		setLevel(fixtures, 1) -- a newer flicker replaces the old one cleanly
	else
		for _, f in fixtures do
			for _, fl in f.lights do
				fl.base = fl.light.Brightness
			end
		end
	end
	flickering = true
	local targets: { Fixture } = {}
	for _, f in fixtures do
		if not near or (f.part.Position - near).Magnitude <= FLICKER_RADIUS then
			table.insert(targets, f)
		end
	end
	-- no fixtures found (map still loading): a gentle grade dip instead
	local viaGrade = #fixtures == 0
	task.spawn(function()
		local t0 = os.clock()
		while token == flickerToken and os.clock() - t0 < seconds do
			local level = 1 - math.min(s * (1 + math.random() * 0.6) * 1.4, 0.92)
			if viaGrade then
				flickerDip = (1 - level) * 0.12
			else
				setLevel(targets, level)
			end
			task.wait(0.08 + math.random() * 0.1)
			if token ~= flickerToken then
				return
			end
			if viaGrade then
				flickerDip = 0
			else
				setLevel(targets, 1)
			end
			task.wait(0.26 + math.random() * 0.5)
		end
		if token == flickerToken then
			setLevel(fixtures, 1)
			flickerDip = 0
			flickering = false
		end
	end)
end

-- Sound, door light, story screens ------------------------------------------------

local function ambience()
	Sfx.play("ambientRoom", { looped = true, volume = 0.3 })
	Sfx.play("rain", { looped = true, volume = 0.22 })
	Sfx.play("fanHum", { looped = true, volume = 0.12 })
	tense = Sfx.play("ambientTense", { looped = true, volume = 0 })
	local finale = Sfx.play("ambientFinale", { looped = true, volume = 0 })
	if finale then
		State.Changed:Connect(function(snap)
			local on = snap.phase == "FinalPurge" or snap.phase == "SignOff" or snap.phase == "ClockOut"
			finale.Volume = if on then 0.45 else 0
		end)
	end
end

local function doorBlink()
	-- 1.25 blinks a second while the rear door is not latched
	local acc = 0
	local on = true
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.4 then
			return
		end
		acc = 0
		local map = workspace:FindFirstChild("Map")
		local inter = map and map:FindFirstChild("Interactive")
		local light = inter and inter:FindFirstChild("DoorStatusLight")
		if light and light:IsA("BasePart") then
			on = not on
			light.LocalTransparencyModifier = if light:GetAttribute("Alert") == true and not on then 0.8 else 0
		end
	end)
end

local function screenTexts()
	-- source monitor messages set by the story (server attribute "Text"),
	-- in soft green phosphor
	local map = workspace:WaitForChild("Map", 20)
	local inter = map and map:WaitForChild("Interactive", 10)
	if not inter then
		return
	end
	for i = 1, 6 do
		local screen = inter:FindFirstChild("SourceScreen_" .. i)
		if screen and screen:IsA("BasePart") then
			local sg = Instance.new("SurfaceGui")
			sg.Name = "StoryText"
			sg.Face = Enum.NormalId.Back
			sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
			sg.PixelsPerStud = 80
			sg.LightInfluence = 0
			sg.Parent = screen
			local t = Instance.new("TextLabel")
			t.Size = UDim2.fromScale(1, 1)
			t.BackgroundTransparency = 1
			t.TextColor3 = PHOSPHOR
			t.FontFace = Fonts.PIXEL
			t.TextScaled = true
			t.TextWrapped = true
			t.Text = ""
			local pad = Instance.new("UIPadding")
			pad.PaddingLeft = UDim.new(0, 6)
			pad.PaddingRight = UDim.new(0, 6)
			pad.PaddingTop = UDim.new(0, 6)
			pad.PaddingBottom = UDim.new(0, 6)
			pad.Parent = t
			t.Parent = sg
			local function sync()
				local v = screen:GetAttribute("Text")
				t.Text = if typeof(v) == "string" then v else ""
				screen.Material = if t.Text ~= "" then Enum.Material.Neon else Enum.Material.SmoothPlastic
				screen.Color = if t.Text ~= "" then Color3.fromRGB(14, 26, 18) else Color3.fromRGB(10, 14, 12)
			end
			screen:GetAttributeChangedSignal("Text"):Connect(sync)
			sync()
		end
	end
end

function Atmosphere.init()
	setupLighting()
	RunService.Heartbeat:Connect(function(dt)
		gradeStep(dt)
		glowStep(dt)
	end)
end

function Atmosphere.start()
	while workspace:GetAttribute("MapReady") ~= true do
		task.wait(0.1)
	end
	applySurfaces()
	collectFixtures()
	buildExteriorFog()
	windowLight()
	-- rain stays outside the walls and doorways
	local A, S, N = Layout.ALLEY, Layout.STREET, NORTH_STREET
	makeRain({ minX = A.minX + 1.5, maxX = A.maxX, minZ = A.minZ, maxZ = A.maxZ }, 40)
	makeRain({ minX = N.minX, maxX = N.maxX, minZ = N.minZ + 0.5, maxZ = N.maxZ - 0.5 }, 40)
	makeRain({ minX = S.minX, maxX = S.maxX, minZ = S.minZ + 1.5, maxZ = S.maxZ }, 40)
	rainOnGlass()
	buildGrain()
	doorBlink()
	ambience()
	task.spawn(screenTexts)
	workspace:GetAttributeChangedSignal("Dread"):Connect(updateDread)
	workspace:GetAttributeChangedSignal("LightsOn"):Connect(updatePower)
	updateDread()
	updatePower()
	for _, plr in Players:GetPlayers() do
		watchPlayer(plr)
	end
	Players.PlayerAdded:Connect(watchPlayer)
end

return Atmosphere
