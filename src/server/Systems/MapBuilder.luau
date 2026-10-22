--!strict
-- Builds the whole office from code at server start: structure, collision,
-- lights, interactive parts and invisible "ArtAnchor" parts that clients turn
-- into meshes from the converted asset library (see client ArtController).
-- Other systems read MapBuilder.refs instead of searching the workspace.
--
-- Art direction: a small, maintained office after hours. Clean painted walls
-- with cream trim, subdued burgundy carpet, a few purposeful objects per desk,
-- soft amber practicals inside and a cold blue-grey night outside.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Layout = require(ReplicatedStorage.Shared.Layout)
local Index = require(ReplicatedStorage.ArtData.Index) :: any

local MapBuilder = {}

export type Refs = {
	map: Folder,
	interactive: Folder,
	sourcePCs: { BasePart },
	sourceLeds: { BasePart },
	sourceScreens: { BasePart },
	drivePlace: { CFrame },
	stagingSlots: { CFrame },
	erasedSlots: { CFrame },
	recoveryRack: BasePart,
	dock: BasePart,
	dockLed: BasePart,
	seat: Seat,
	seatPromptPart: BasePart,
	monitorScreen: BasePart,
	breakerSwitches: { [string]: BasePart },
	breakerLamps: { [string]: BasePart },
	rearDoor: BasePart,
	rearDoorHinge: CFrame,
	doorLight: BasePart,
	doorPromptPart: BasePart,
	frontDoors: { BasePart },
	timeClock: BasePart,
	kitchenTrash: BasePart,
	dumpster: BasePart,
	thermostat: BasePart,
	printer: BasePart,
	printerLed: BasePart,
	outbox: BasePart,
	threatAnchorKey: string,
	shiftChair: BasePart,
	lights: { [string]: { Light } },
	emergencyLights: { Light },
	deskLamps: { Light },
	workstationLamp: Light,
	fixtures: { [string]: { BasePart } },
	noticeBoards: { BasePart },
	crewFigures: { BasePart },
	escapeZone: BasePart,
}

MapBuilder.refs = (nil :: any) :: Refs

-- Palette (albedo). Shadow tone comes from Lighting.Ambient, not from paint.
local C = {
	wall = Color3.fromRGB(205, 200, 186), -- fallback under the cream plaster texture
	trim = Color3.fromRGB(183, 176, 156), -- muted cream: painted trim, old plastic
	carpet = Color3.fromRGB(96, 73, 77), -- dusty burgundy
	curtain = Color3.fromRGB(96, 73, 77),
	ceiling = Color3.fromRGB(204, 203, 196),
	beige = Color3.fromRGB(183, 176, 156),
	metal = Color3.fromRGB(118, 122, 126),
	dark = Color3.fromRGB(34, 38, 42),
	brick = Color3.fromRGB(92, 84, 78),
	asphalt = Color3.fromRGB(44, 46, 50),
	glass = Color3.fromRGB(120, 140, 155),
	fluorescent = Color3.fromRGB(222, 224, 214), -- fixture panel (neon, kept soft)
	fluorescentLight = Color3.fromRGB(238, 234, 220), -- light cast by the panels
	amber = Color3.fromRGB(200, 166, 107), -- practicals: desk lamps, hall bulbs
	cold = Color3.fromRGB(168, 186, 195), -- exterior: pale blue-grey
}

local SILKSCREEN = "rbxassetid://12187371840"

local root: Folder = (nil :: any) :: Folder
local groups: { [string]: Folder } = {}

local function group(name: string): Folder
	local existing = groups[name]
	if existing then
		return existing
	end
	local g = Instance.new("Folder")
	g.Name = name
	g.Parent = root
	groups[name] = g
	return g
end

type PartOpts = {
	color: Color3?,
	material: Enum.Material?,
	transparency: number?,
	collide: boolean?,
	surface: string?, -- surface texture name (client applies the EditableImage)
	tile: number?,
	shadow: boolean?,
	query: boolean?,
}

local function addSurface(p: BasePart, surface: string, tile: number, faces: { Enum.NormalId }?)
	local list: { Enum.NormalId } = faces or { Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right, Enum.NormalId.Top, Enum.NormalId.Bottom }
	for _, face in list do
		local t = Instance.new("Texture")
		t.Face = face
		t.StudsPerTileU = tile
		t.StudsPerTileV = tile
		t.Transparency = 0.05
		t:SetAttribute("Surface", surface)
		CollectionService:AddTag(t, "Surface")
		t.Parent = p
	end
end

local function part(name: string, size: Vector3, cf: CFrame, parent: Instance, o: PartOpts?): Part
	local opts: PartOpts = o or {}
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = opts.color or C.beige
	p.Material = opts.material or Enum.Material.SmoothPlastic
	p.Transparency = opts.transparency or 0
	p.CanCollide = if opts.collide == nil then true else opts.collide
	p.CastShadow = if opts.shadow == nil then true else opts.shadow
	p.CanQuery = if opts.query == nil then true else opts.query
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if opts.surface then
		addSurface(p, opts.surface, opts.tile or 8)
	end
	p.Parent = parent
	return p
end

local function box(name: string, minV: Vector3, maxV: Vector3, parent: Instance, o: PartOpts?): Part
	return part(name, maxV - minV, CFrame.new((minV + maxV) / 2), parent, o)
end

-- Axis-aligned wall along X (constant z) or Z (constant x) with openings.
type Gap = { from: number, to: number, bottom: number, top: number }

local function wall(name: string, axis: "X" | "Z", fixed: number, a: number, b: number, height: number, gaps: { Gap }, o: PartOpts?)
	local parent = group("Structure")
	local t = Layout.WALL
	table.sort(gaps, function(g1, g2)
		return g1.from < g2.from
	end)
	local function seg(s0: number, s1: number, y0: number, y1: number)
		if s1 - s0 < 0.05 or y1 - y0 < 0.05 then
			return
		end
		local minV, maxV
		if axis == "X" then
			minV, maxV = Vector3.new(s0, y0, fixed - t / 2), Vector3.new(s1, y1, fixed + t / 2)
		else
			minV, maxV = Vector3.new(fixed - t / 2, y0, s0), Vector3.new(fixed + t / 2, y1, s1)
		end
		box(name, minV, maxV, parent, o)
	end
	local cursor = a
	for _, g in gaps do
		seg(cursor, g.from, 0, height)
		seg(g.from, g.to, 0, g.bottom)
		seg(g.from, g.to, g.top, height)
		cursor = g.to
	end
	seg(cursor, b, 0, height)
end

-- Painted wainscot: skirting board, flat lower panel and a chair rail along
-- the inside face of a wall. `inward` is +1/-1 along the wall's normal axis.
local function trim(name: string, axis: "X" | "Z", fixed: number, a: number, b: number, inward: number, gaps: { { number } })
	local parent = group("Structure")
	local face = fixed + inward * (Layout.WALL / 2)
	local opts: PartOpts = { color = C.trim, collide = false, shadow = false }
	local function slab(s0: number, s1: number, y0: number, y1: number, depth: number)
		if s1 - s0 < 0.05 then
			return
		end
		local d0, d1 = face, face + inward * depth
		local lo, hi = math.min(d0, d1), math.max(d0, d1)
		if axis == "X" then
			box(name, Vector3.new(s0, y0, lo), Vector3.new(s1, y1, hi), parent, opts)
		else
			box(name, Vector3.new(lo, y0, s0), Vector3.new(hi, y1, s1), parent, opts)
		end
	end
	local sorted = table.clone(gaps)
	table.sort(sorted, function(g1, g2)
		return g1[1] < g2[1]
	end)
	local function run(s0: number, s1: number)
		slab(s0, s1, 0, 2.7, 0.06) -- panel
		slab(s0, s1, 0, 0.35, 0.12) -- skirting
		slab(s0, s1, 2.7, 2.86, 0.12) -- chair rail
	end
	local cursor = a
	for _, g in sorted do
		run(cursor, g[1])
		cursor = g[2]
	end
	run(cursor, b)
end

local function region(name: string, r: { minX: number, maxX: number, minZ: number, maxZ: number }, y0: number, y1: number, o: PartOpts?): Part
	return box(name, Vector3.new(r.minX, y0, r.minZ), Vector3.new(r.maxX, y1, r.maxZ), group("Structure"), o)
end

-- Art props ------------------------------------------------------------------

local ART_YAW: { [string]: number } = {
	characters__male__character_01 = 180,
	characters__male__character_04 = 180,
	characters__male__character_05 = 180,
	-- office chairs: the source seat faces -Z
	office__chairs__office_chair_grey = 180,
	office__chairs__office_chair_black = 180,
	office__chairs__office_chair_blue = 180,
	office__chairs__office_chair_black_alt = 180,
	office__chairs__office_chair_grey_alt = -90,
}

-- Props placed by their centre (wall fixtures). Everything else is lifted so
-- the bottom of its mesh rests on the given position (several source models
-- are centred vertically and would otherwise sink into floors and desks).
local CENTRE_PLACED: { [string]: boolean } = {
	classic64__blend__panel_electrical_closed = true,
	classic64__blend__panel_electric = true,
	classic64__blend__panel_thermostat = true,
	classic64__blend__electrical_junctionbox_small = true,
	classic64__blend__fire_extenguisher_case = true,
	office__extras__wall_clock = true,
}

type PropOpts = {
	scale: number?,
	collide: boolean?,
	yaw: number?,
	dynamic: boolean?,
	tint: Color3?,
	pad: number?,
	parent: Instance?,
}

local function prop(key: string, pos: Vector3, front: Vector3, o: PropOpts?): BasePart?
	local opts: PropOpts = o or {}
	local info = Index.models[key]
	if not info then
		warn("[Map] unknown art key", key)
		return nil
	end
	local s = opts.scale or 1
	local cf = Layout.facing(pos, front, (opts.yaw or 0) + (ART_YAW[key] or 0))
	local minY: number = info.min.Y
	if not CENTRE_PLACED[key] and minY < -0.02 then
		cf = cf * CFrame.new(0, -minY * s, 0)
	end
	local anchor = Instance.new("Part")
	anchor.Name = key
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = cf
	anchor:SetAttribute("ArtKey", key)
	if s ~= 1 then
		anchor:SetAttribute("ArtScale", s)
	end
	if opts.tint then
		anchor:SetAttribute("ArtTint", opts.tint)
	end
	if opts.dynamic then
		anchor:SetAttribute("ArtDynamic", true)
	end
	CollectionService:AddTag(anchor, "ArtAnchor")
	anchor.Parent = opts.parent or group("Props")
	if opts.collide then
		local mn: Vector3 = info.min * s
		local mx: Vector3 = info.max * s
		local pad = opts.pad or 0
		local size = (mx - mn) - Vector3.new(pad, 0, pad) * 2
		local c = cf * CFrame.new((mn + mx) / 2)
		part(key .. "_Collision", Vector3.new(math.max(size.X, 0.3), math.max(size.Y, 0.3), math.max(size.Z, 0.3)), c, group("Collision"), {
			transparency = 1,
			shadow = false,
		})
	end
	return anchor
end

-- Short retro labels on physical objects (dock, breakers, signs): pixel font.
local function label(p: BasePart, face: Enum.NormalId, text: string, color: Color3?, bg: Color3?, textSize: number?): TextLabel
	local sg = Instance.new("SurfaceGui")
	sg.Face = face
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 50
	sg.LightInfluence = 0.6
	sg.Parent = p
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundColor3 = bg or Color3.new(0, 0, 0)
	t.BackgroundTransparency = if bg then 0 else 1
	t.TextColor3 = color or Color3.new(0.1, 0.1, 0.1)
	t.FontFace = Font.new(SILKSCREEN)
	t.TextScaled = textSize == nil
	if textSize then
		t.TextSize = textSize
	end
	t.TextWrapped = true
	t.Text = text
	t.Parent = sg
	return t
end

-- Lights ---------------------------------------------------------------------

local lightGroups: { [string]: { Light } } = {}
local fixtures: { [string]: { BasePart } } = {}

local function fluorescent(groupName: string, pos: Vector3, ceiling: number, color: Color3?, brightness: number?)
	local fixture = part("Fluorescent", Vector3.new(6, 0.25, 2), CFrame.new(pos.X, ceiling - 0.13, pos.Z), group("Lights"), {
		color = C.fluorescent,
		material = Enum.Material.Neon,
		collide = false,
		shadow = false,
	})
	local frame = part("FluorescentFrame", Vector3.new(6.4, 0.18, 2.4), CFrame.new(pos.X, ceiling - 0.05, pos.Z), group("Lights"), {
		color = C.metal,
		collide = false,
		shadow = false,
	})
	frame.Parent = fixture
	local light = Instance.new("SurfaceLight")
	light.Face = Enum.NormalId.Bottom
	light.Angle = 120
	light.Range = 15
	light.Brightness = brightness or 0.8
	light.Color = color or C.fluorescentLight
	light.Shadows = true
	light.Parent = fixture
	lightGroups[groupName] = lightGroups[groupName] or {}
	table.insert(lightGroups[groupName], light)
	fixtures[groupName] = fixtures[groupName] or {}
	table.insert(fixtures[groupName], fixture)
end

local function pointLight(groupName: string, pos: Vector3, color: Color3, range: number, brightness: number, parent: Instance?): PointLight
	local holder = part("LightPoint", Vector3.new(0.2, 0.2, 0.2), CFrame.new(pos), parent or group("Lights"), {
		transparency = 1,
		collide = false,
		shadow = false,
		query = false,
	})
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = range
	light.Brightness = brightness
	light.Shadows = true
	light.Parent = holder
	lightGroups[groupName] = lightGroups[groupName] or {}
	table.insert(lightGroups[groupName], light)
	return light
end

-- Builders -------------------------------------------------------------------

local function buildStructure()
	local M, K, L, H, A = Layout.MAIN, Layout.KITCHEN, Layout.LOBBY, Layout.HALL, Layout.ALLEY
	local ceil = Layout.CEILING

	-- floors
	region("FloorMain", M, -1, 0, { color = C.carpet, material = Enum.Material.Carpet, surface = "carpet", tile = 7 })
	region("FloorKitchen", K, -1, 0, { color = C.beige, surface = "floor_tile", tile = 6 })
	region("FloorLobby", L, -1, 0, { color = C.beige, surface = "floor_lobby", tile = 6 })
	region("FloorHall", H, -1, 0, { color = C.metal, material = Enum.Material.Concrete, surface = "floor_concrete", tile = 8 })
	region("FloorAlley", A, -1, 0, { color = C.asphalt, material = Enum.Material.Asphalt })
	region("FloorAlleyBeyond", { minX = 66, maxX = 82, minZ = -6, maxZ = 16 }, -1, 0, { color = C.dark, material = Enum.Material.Asphalt })
	region("FloorStreet", Layout.STREET, -1, 0, { color = C.asphalt, material = Enum.Material.Asphalt })
	region("FloorNorthStreet", { minX = -34, maxX = 36, minZ = -30, maxZ = -14.5 }, -1, 0, { color = C.asphalt, material = Enum.Material.Asphalt })
	-- the hall entrance strip between the room wall and the hall
	box("FloorGap", Vector3.new(21.5, -1, 3), Vector3.new(22.5, 0, 9), group("Structure"), { color = C.carpet, material = Enum.Material.Carpet })
	box("FloorGapK", Vector3.new(-22.5, -1, -12), Vector3.new(-21.5, 0, -5.5), group("Structure"), { color = C.carpet, material = Enum.Material.Carpet })
	box("FloorGapL", Vector3.new(9, -1, 13.5), Vector3.new(15, 0, 14.5), group("Structure"), { color = C.carpet, material = Enum.Material.Carpet })

	-- ceilings: acoustic tile grid
	local ceilOpts: PartOpts = { color = C.ceiling, surface = "ceiling_tile", tile = 8 }
	region("CeilingMain", { minX = M.minX - 1, maxX = M.maxX + 1, minZ = M.minZ - 1, maxZ = M.maxZ + 1 }, ceil, ceil + 1, ceilOpts)
	region("CeilingKitchen", K, ceil - 1, ceil, ceilOpts)
	region("CeilingLobby", L, ceil, ceil + 1, ceilOpts)
	region("CeilingHall", H, 9, 10, { color = C.metal, surface = "wall_concrete", tile = 8 })

	local officeWall: PartOpts = { color = C.wall, surface = "wall_office", tile = 9 }
	local doorGap = function(f: number, t: number, top: number): Gap
		return { from = f, to = t, bottom = 0, top = top }
	end

	-- main room
	local windows: { Gap } = {}
	for _, x in Layout.WINDOWS_X do
		table.insert(windows, { from = x - 3, to = x + 3, bottom = 3.3, top = 7.6 })
	end
	wall("WallNorth", "X", M.minZ - 0.5, M.minX - 1, M.maxX + 1, ceil, windows, officeWall)
	wall("WallSouth", "X", M.maxZ + 0.5, M.minX - 1, M.maxX + 1, ceil, { doorGap(Layout.LOBBY_GAP.minX, Layout.LOBBY_GAP.maxX, 8) }, officeWall)
	wall("WallWest", "Z", M.minX - 0.5, M.minZ, M.maxZ, ceil, { doorGap(Layout.KITCHEN_GAP.minZ, Layout.KITCHEN_GAP.maxZ, 8) }, officeWall)
	wall("WallEast", "Z", M.maxX + 0.5, M.minZ, M.maxZ, ceil, { doorGap(Layout.HALL_GAP.minZ, Layout.HALL_GAP.maxZ, 8.5) }, officeWall)
	-- painted trim: skirting, wainscot panel and chair rail on every office wall
	trim("Trim", "X", M.minZ - 0.5, M.minX, M.maxX, 1, {})
	trim("Trim", "X", M.maxZ + 0.5, M.minX, M.maxX, -1, { { Layout.LOBBY_GAP.minX, Layout.LOBBY_GAP.maxX } })
	trim("Trim", "Z", M.minX - 0.5, M.minZ, M.maxZ, 1, { { Layout.KITCHEN_GAP.minZ, Layout.KITCHEN_GAP.maxZ } })
	trim("Trim", "Z", M.maxX + 0.5, M.minZ, M.maxZ, -1, { { Layout.HALL_GAP.minZ, Layout.HALL_GAP.maxZ } })
	-- door frames (cream) around the openings
	for _, spec in {
		{ Vector3.new(Layout.LOBBY_GAP.minX - 0.25, 0, M.maxZ - 0.1), Vector3.new(Layout.LOBBY_GAP.minX, 8.2, M.maxZ + 1.1) },
		{ Vector3.new(Layout.LOBBY_GAP.maxX, 0, M.maxZ - 0.1), Vector3.new(Layout.LOBBY_GAP.maxX + 0.25, 8.2, M.maxZ + 1.1) },
		{ Vector3.new(Layout.LOBBY_GAP.minX - 0.25, 8, M.maxZ - 0.1), Vector3.new(Layout.LOBBY_GAP.maxX + 0.25, 8.25, M.maxZ + 1.1) },
		{ Vector3.new(M.minX - 1.1, 0, Layout.KITCHEN_GAP.minZ - 0.25), Vector3.new(M.minX + 0.1, 8.2, Layout.KITCHEN_GAP.minZ) },
		{ Vector3.new(M.minX - 1.1, 0, Layout.KITCHEN_GAP.maxZ), Vector3.new(M.minX + 0.1, 8.2, Layout.KITCHEN_GAP.maxZ + 0.25) },
		{ Vector3.new(M.minX - 1.1, 8, Layout.KITCHEN_GAP.minZ - 0.25), Vector3.new(M.minX + 0.1, 8.25, Layout.KITCHEN_GAP.maxZ + 0.25) },
	} do
		box("DoorFrame", spec[1], spec[2], group("Structure"), { color = C.trim, collide = false })
	end

	-- windows: glass, sill, frame, mullion, rain streaks and faded curtains
	for _, x in Layout.WINDOWS_X do
		part("WindowGlass", Vector3.new(6, 4.3, 0.15), CFrame.new(x, 5.45, M.minZ - 0.5), group("Structure"), {
			color = C.glass,
			material = Enum.Material.SmoothPlastic,
			transparency = 0.6,
			shadow = false,
		})
		part("WindowSill", Vector3.new(6.6, 0.22, 0.9), CFrame.new(x, 3.22, M.minZ + 0.1), group("Structure"), { color = C.trim })
		part("WindowFrame", Vector3.new(6.6, 0.18, 0.25), CFrame.new(x, 7.68, M.minZ - 0.2), group("Structure"), { color = C.trim, collide = false })
		for _, side in { -1, 1 } do
			part("WindowFrame", Vector3.new(0.18, 4.5, 0.25), CFrame.new(x + side * 3.1, 5.45, M.minZ - 0.2), group("Structure"), { color = C.trim, collide = false })
		end
		part("WindowMullion", Vector3.new(0.16, 4.3, 0.22), CFrame.new(x, 5.45, M.minZ - 0.4), group("Structure"), { color = C.trim, collide = false })
		part("WindowRainStreaks", Vector3.new(5.9, 4.2, 0.05), CFrame.new(x, 5.45, M.minZ - 0.38), group("Structure"), {
			transparency = 1,
			collide = false,
			shadow = false,
			query = false,
		}):SetAttribute("RainGlass", true)
		part("CurtainRod", Vector3.new(8.6, 0.1, 0.1), CFrame.new(x, 8.05, M.minZ + 0.45), group("Structure"), { color = C.metal, collide = false, shadow = false })
		for _, side in { -1, 1 } do
			part("Curtain", Vector3.new(1.1, 4.9, 0.28), CFrame.new(x + side * 3.7, 5.55, M.minZ + 0.45), group("Structure"), {
				color = C.curtain,
				material = Enum.Material.Fabric,
				collide = false,
			})
		end
	end
	-- building across the street (seen through the windows): a few lit windows, muted
	box("FacadeAcross", Vector3.new(-34, 0, -31), Vector3.new(36, 30, -30), group("Structure"), {
		color = Color3.fromRGB(46, 48, 52),
		surface = "brick_alley",
		tile = 10,
	})
	for i, x in { -20, -6, 4, 18 } do
		local lit = i % 2 == 0
		part("FacadeWindow", Vector3.new(3, 3, 0.2), CFrame.new(x, 6 + (i % 3) * 5, -29.9), group("Structure"), {
			color = if lit then C.amber else Color3.fromRGB(28, 32, 38),
			material = if lit then Enum.Material.Neon else Enum.Material.SmoothPlastic,
			transparency = if lit then 0.5 else 0,
			collide = false,
		})
	end
	prop("urban__traffic_lights__street_light", Vector3.new(-6, 0, -24), Vector3.new(0, 0, 1), {})
	pointLight("exterior", Vector3.new(-6, 21, -23), C.cold, 30, 0.9)

	-- kitchenette: same clean plaster, a frosted window instead of boards
	local kitchenWall: PartOpts = { color = C.wall, surface = "wall_kitchen", tile = 9 }
	wall("KitchenNorth", "X", K.minZ - 0.5, K.minX - 1, M.minX - 1, ceil, {}, kitchenWall)
	wall("KitchenSouth", "X", K.maxZ + 0.5, K.minX - 1, M.minX - 1, ceil, {}, kitchenWall)
	wall("KitchenWest", "Z", K.minX - 0.5, K.minZ, K.maxZ, ceil, { { from = -10, to = -7, bottom = 3.6, top = 6.6 } }, kitchenWall)
	part("KitchenWindow", Vector3.new(0.15, 3, 3), CFrame.new(K.minX - 0.5, 5.1, -8.5), group("Structure"), {
		color = Color3.fromRGB(150, 165, 175),
		material = Enum.Material.SmoothPlastic,
		transparency = 0.35,
		shadow = false,
	})
	part("KitchenWindowSill", Vector3.new(0.8, 0.2, 3.3), CFrame.new(K.minX + 0.1, 3.5, -8.5), group("Structure"), { color = C.trim })

	-- lobby
	wall("LobbyWest", "Z", L.minX - 0.5, L.minZ, L.maxZ + 1, ceil, {}, officeWall)
	wall("LobbyEast", "Z", L.maxX + 0.5, L.minZ, L.maxZ + 1, ceil, {}, officeWall)
	wall("LobbySouth", "X", L.maxZ + 0.5, L.minX - 1, L.maxX + 1, ceil, { doorGap(Layout.FRONT_DOOR.minX, Layout.FRONT_DOOR.maxX, Layout.FRONT_DOOR.height) }, officeWall)
	trim("Trim", "Z", L.minX - 0.5, L.minZ, L.maxZ, 1, {})
	trim("Trim", "Z", L.maxX + 0.5, L.minZ, L.maxZ, -1, {})

	-- utility hall
	local hallWall: PartOpts = { color = Color3.fromRGB(150, 152, 150), surface = "wall_concrete", tile = 7 }
	wall("HallNorth", "X", H.minZ - 0.5, H.minX + 0.5, H.maxX, 9, {}, hallWall)
	wall("HallSouth", "X", H.maxZ + 0.5, H.minX + 0.5, H.maxX, 9, {}, hallWall)
	box("HallHeader", Vector3.new(H.minX - 0.5, 8.5, H.minZ), Vector3.new(H.minX + 0.5, ceil, H.maxZ), group("Structure"), officeWall)
	-- exterior wall with the rear door
	local RD = Layout.REAR_DOOR
	wall("RearWall", "Z", RD.x + 0.5, -6, 16, 13, { doorGap(RD.minZ, RD.maxZ, RD.height) }, {
		color = C.brick,
		surface = "brick_alley",
		tile = 8,
	})
	box("RearDoorFrameTop", Vector3.new(RD.x - 0.1, RD.height, RD.minZ - 0.3), Vector3.new(RD.x + 1.1, RD.height + 0.4, RD.maxZ + 0.3), group("Structure"), { color = C.metal })

	-- alley walls
	local brick: PartOpts = { color = C.brick, surface = "brick_alley", tile = 8 }
	wall("AlleyNorth", "X", A.minZ - 0.5, RD.x, A.maxX + 16, 14, {}, brick)
	wall("AlleySouth", "X", A.maxZ + 0.5, RD.x, A.maxX + 16, 14, {}, brick)
	box("AlleyBack", Vector3.new(82, 0, A.minZ), Vector3.new(83, 14, A.maxZ), group("Structure"), { color = C.dark })
	-- invisible fence line beyond the alley mouth keeps players in the playable area
	local limit = box("AlleyLimit", Vector3.new(66, 0, A.minZ), Vector3.new(66.5, 14, A.maxZ), group("Structure"), { transparency = 1, collide = true })
	limit.CollisionGroup = "PlayerLimit"
	-- street outside the front door
	local S = Layout.STREET
	box("StreetLimitS", Vector3.new(S.minX, 0, S.maxZ), Vector3.new(S.maxX, 14, S.maxZ + 1), group("Structure"), { transparency = 1 })
	box("StreetLimitW", Vector3.new(S.minX - 1, 0, S.minZ), Vector3.new(S.minX, 14, S.maxZ), group("Structure"), { transparency = 1 })
	box("StreetLimitE", Vector3.new(S.maxX, 0, S.minZ), Vector3.new(S.maxX + 1, 14, S.maxZ), group("Structure"), { transparency = 1 })
	box("CurbFacade", Vector3.new(S.minX - 4, 0, S.maxZ + 1), Vector3.new(S.maxX + 4, 22, S.maxZ + 2), group("Structure"), {
		color = Color3.fromRGB(42, 42, 46),
		surface = "brick_alley",
		tile = 10,
	})
	-- rooftop caps so the sky is not visible through gaps
	box("RoofCap", Vector3.new(-32, ceil + 1, -15), Vector3.new(37, ceil + 1.6, 24), group("Structure"), { color = C.dark })
end

local function buildDesks(refs: Refs)
	local props = group("Props")
	-- a few purposeful objects per desk; some surfaces stay almost empty
	local deskItems: { { { key: string, dx: number, dz: number, yaw: number } } } = {
		{ { key = "office__extras__mug", dx = -2.2, dz = 0.2, yaw = 40 }, { key = "office__stationary__paper_stack", dx = -1.5, dz = -0.3, yaw = 12 } },
		{ { key = "office__book_things__file_binder", dx = -2.4, dz = -0.6, yaw = 100 } },
		{ { key = "office__stationary__paper_stack_large", dx = -1.6, dz = -0.2, yaw = -8 }, { key = "office__extras__circular_desklamp", dx = -3.0, dz = -0.9, yaw = 0 } },
		{ { key = "office__extras__mug_alt2", dx = -2.0, dz = 0.3, yaw = 160 } },
		{ { key = "office__extras__square_desklamp", dx = -3.0, dz = -1.0, yaw = 0 } },
		{ { key = "office__stationary__paper_single_sheet", dx = -1.8, dz = 0.4, yaw = 25 } },
	}
	local lampDesks: { [number]: boolean } = { [3] = true, [5] = true }
	for i, d in Layout.DESKS do
		local f = d.front
		local right = Vector3.new(-f.Z, 0, f.X) -- right-hand side seen by the desk user
		local top = Layout.DESK_TOP
		prop(d.art, d.pos, f, { collide = true, pad = 0.1 })
		-- seated side faces the desk: chair front points back toward the desk.
		-- Chairs get a slim collision box so the first-person camera never clips them.
		prop(d.chair, d.pos + f * 3.1 + right * 0.4, -f, { yaw = (i * 17) % 30 - 15, collide = true, pad = 0.5 })
		-- monitor, keyboard, mouse
		prop("office__computers__computer_monitor", d.pos - f * 0.7 + Vector3.new(0, top, 0), f)
		prop("office__computers__computer_keyboard", d.pos + f * 0.7 + Vector3.new(0, top, 0), f)
		prop("office__computers__computer_mouse", d.pos + f * 0.8 + right * 1.4 + Vector3.new(0, top, 0), f)
		for _, item in deskItems[i] do
			prop(item.key, d.pos + f * item.dz + right * item.dx + Vector3.new(0, top, 0), f, { yaw = item.yaw })
		end
		if lampDesks[i] then
			pointLight("lamps", d.pos - f * 0.6 - right * 3.0 + Vector3.new(0, top + 1.2, 0), C.amber, 8, 0.7)
		end

		-- source computer tower (holds the drive) on the desk's right side
		local towerKey = if i % 2 == 0 then "office__computers__computer_tower_alt" else "office__computers__computer_tower"
		local towerPos = d.pos - f * 0.4 + right * 2.75 + Vector3.new(0, top, 0)
		prop(towerKey, towerPos, f)
		local towerCf = Layout.facing(towerPos + Vector3.new(0, 1.07, 0), f)
		local pc = part("SourcePC_" .. i, Vector3.new(1.0, 2.15, 2.15), towerCf, group("Interactive"), {
			transparency = 1,
			collide = false,
		})
		pc:SetAttribute("Desk", i)
		local led = part("SourceLed_" .. i, Vector3.new(0.12, 0.12, 0.05), towerCf * CFrame.new(0.25, 0.75, -1.09), group("Interactive"), {
			color = Color3.fromRGB(80, 255, 120),
			material = Enum.Material.Neon,
			collide = false,
			shadow = false,
		})
		refs.sourcePCs[i] = pc
		refs.sourceLeds[i] = led
		-- where the drive visibly sits while installed (front bay)
		refs.drivePlace[i] = towerCf * CFrame.new(0, 0.35, -0.95)
		-- source monitor screen surface (harmless disturbance lights it up)
		local monCf = Layout.facing(d.pos - f * 0.7 + Vector3.new(0, top + 1.05, 0), f) * CFrame.new(0, 0, 0.52)
		local screen = part("SourceScreen_" .. i, Vector3.new(1.55, 1.15, 0.05), monCf, group("Interactive"), {
			color = Color3.fromRGB(10, 14, 12),
			collide = false,
			shadow = false,
		})
		refs.sourceScreens[i] = screen
	end

	-- low grey partitions between the two desk rows and at the cluster ends
	for _, x in { -14, -5.6, 2.8 } do
		prop("office__dividers__divider_black_low", Vector3.new(x, 0, 0), Vector3.new(0, 0, 1), { collide = true, scale = 0.76 })
	end
	prop("office__dividers__divider_black_low_half", Vector3.new(-18.6, 0, -3.2), Vector3.new(1, 0, 0), { collide = true, scale = 0.76 })
	prop("office__dividers__divider_black_low", Vector3.new(7.3, 0, 0), Vector3.new(1, 0, 0), { collide = true, scale = 0.76 })

	-- the chair that can "shift" on its own (dynamic mesh)
	local shift = prop("office__chairs__conference_chair_grey", Vector3.new(-9.8, 0, 7.4), Vector3.new(0, 0, -1), { dynamic = true })
	assert(shift, "shift chair")
	refs.shiftChair = shift
	local _ = props
end

local function buildWorkstation(refs: Refs)
	local W = Layout.WORKSTATION
	local f = W.facing -- operator looks into the corner
	prop("office__desks__desk2_corner", W.desk, Vector3.new(-1, 0, 0), { collide = false })
	-- corner desk collision: two slabs along the walls so the chair area stays open
	box("WSDeskNorth", Vector3.new(14.3, 0, -14), Vector3.new(22, Layout.DESK_TOP, -10.9), group("Collision"), { transparency = 1 })
	box("WSDeskEast", Vector3.new(18.9, 0, -10.9), Vector3.new(22, Layout.DESK_TOP, -6.3), group("Collision"), { transparency = 1 })

	prop("office__computers__computer_monitor", W.monitor, -f, { scale = 1.15 })
	prop("office__computers__computer_keyboard", W.monitor - f * 1.4 + Vector3.new(0, 0, 0), -f)
	prop("office__computers__computer_mouse", W.monitor - f * 1.5 + Vector3.new(1.1, 0, 1.1), -f)
	prop("office__extras__circular_desklamp", W.lamp, Vector3.new(0, 0, 1))
	prop("office__extras__mug_alt", Vector3.new(19.2, Layout.DESK_TOP, -13.3), Vector3.new(0, 0, 1))
	prop("office__extras__desk_phone_with_cable", Vector3.new(21.1, Layout.DESK_TOP, -12.4), Vector3.new(-1, 0, 0))
	prop("office__stationary__pen2", Vector3.new(18.4, Layout.DESK_TOP, -12.3), Vector3.new(0, 0, 1))
	refs.workstationLamp = pointLight("workstation", W.lamp + Vector3.new(0, 1.4, 0.5), C.amber, 11, 1.0)
	refs.workstationLamp.Shadows = true

	-- physical monitor surface showing simplified job progress to the team
	local monCf = Layout.facing(W.monitor + Vector3.new(0, 1.2, 0), -f) * CFrame.new(0, 0, 0.62)
	local screen = part("WorkstationScreen", Vector3.new(1.8, 1.32, 0.05), monCf, group("Interactive"), {
		color = Color3.fromRGB(16, 32, 60),
		material = Enum.Material.Neon,
		collide = false,
		shadow = false,
	})
	refs.monitorScreen = screen

	-- chair + seat (touch-sitting disabled; players use the prompt)
	prop("office__chairs__office_chair_grey", W.chair, f)
	local seatCf = CFrame.lookAt(W.chair + Vector3.new(0, 1.45, 0), W.chair + f + Vector3.new(0, 1.45, 0))
	local seat = Instance.new("Seat")
	seat.Name = "WorkstationSeat"
	seat.Anchored = true
	seat.Size = Vector3.new(2, 0.4, 2)
	seat.CFrame = seatCf
	seat.Transparency = 1
	seat.CanTouch = false
	seat.CanCollide = false
	seat.Parent = group("Interactive")
	refs.seat = seat
	refs.seatPromptPart = part("SeatPrompt", Vector3.new(1, 1, 1), CFrame.new(W.chair + Vector3.new(0, 2.6, 0)), group("Interactive"), {
		transparency = 1,
		collide = false,
	})

	-- drive dock (cream box with a slot and a status LED)
	local dockCf = CFrame.new(W.dock + Vector3.new(0, 0.45, 0)) * CFrame.Angles(0, math.rad(90), 0)
	local dock = part("DriveDock", Vector3.new(1.6, 0.9, 1.9), dockCf, group("Interactive"), {
		color = Color3.fromRGB(196, 190, 170),
	})
	label(dock, Enum.NormalId.Front, "DOCK", Color3.fromRGB(40, 40, 40))
	part("DockSlot", Vector3.new(1.25, 0.12, 0.05), dockCf * CFrame.new(0, 0.12, -0.96), group("Interactive"), { color = C.dark, collide = false })
	refs.dock = dock
	refs.dockLed = part("DockLed", Vector3.new(0.12, 0.12, 0.05), dockCf * CFrame.new(0.6, -0.25, -0.96), group("Interactive"), {
		color = Color3.fromRGB(60, 60, 60),
		material = Enum.Material.Neon,
		collide = false,
	})
	refs.outbox = part("Outbox", Vector3.new(1.4, 0.3, 1.0), CFrame.new(Layout.OUTBOX + Vector3.new(0, 0.15, 0)), group("Interactive"), {
		color = Color3.fromRGB(90, 90, 96),
	})
	label(refs.outbox, Enum.NormalId.Top, "OUT TRAY", Color3.new(0.9, 0.9, 0.9))

	-- drive rack beside the workstation
	local R = Layout.RACK
	prop("classic64__blend__metal_rack_stackable", R.pos, R.front, { collide = true })
	for i = 1, 6 do
		local x = R.slotX0 + (i - 1) * R.slotDX
		refs.stagingSlots[i] = CFrame.new(x, R.stagingY + 0.75, R.slotZ) * CFrame.Angles(0, 0, math.rad(90))
		refs.erasedSlots[i] = CFrame.new(x, R.erasedY + 0.75, R.slotZ) * CFrame.Angles(0, 0, math.rad(90))
	end
	local rackSign = part("RackSign", Vector3.new(5, 0.9, 0.1), CFrame.new(R.pos + Vector3.new(0, 5.6, -0.6)), group("Interactive"), {
		color = Color3.fromRGB(226, 221, 200),
		collide = false,
	})
	label(rackSign, Enum.NormalId.Back, "DRIVE RACK  top: STAGING / RECOVERY   lower: ERASED", Color3.fromRGB(30, 30, 30))
	refs.recoveryRack = part("RackPrompt", Vector3.new(5, 3.5, 1), CFrame.new(R.pos + Vector3.new(0, 2.6, 0.6)), group("Interactive"), {
		transparency = 1,
		collide = false,
	})

	-- door status light visible from the workstation chair
	refs.doorLight = part("DoorStatusLight", Vector3.new(0.5, 0.5, 0.2), CFrame.new(Layout.DOOR_LIGHT), group("Interactive"), {
		color = Color3.fromRGB(60, 255, 90),
		material = Enum.Material.Neon,
		collide = false,
	})
	local dl = Instance.new("PointLight")
	dl.Range = 6
	dl.Brightness = 0.6
	dl.Color = Color3.fromRGB(60, 255, 90)
	dl.Parent = refs.doorLight
	local dlSign = part("DoorStatusSign", Vector3.new(2.6, 0.6, 0.1), CFrame.new(Layout.DOOR_LIGHT + Vector3.new(0, -0.7, 0)) * CFrame.Angles(0, math.rad(90), 0), group("Interactive"), {
		color = C.dark,
		collide = false,
	})
	label(dlSign, Enum.NormalId.Front, "REAR DOOR", Color3.new(0.9, 0.9, 0.9))
	label(dlSign, Enum.NormalId.Back, "REAR DOOR", Color3.new(0.9, 0.9, 0.9))
end

local function buildRooms(refs: Refs)
	local M = Layout.MAIN
	-- south wall: bookcase, cabinets, printer
	prop("office__book_things__book_case_with_back_small", Vector3.new(-17.0, 0, M.maxZ - 0.8), Vector3.new(0, 0, -1), { collide = true, scale = 0.8 })
	prop("office__book_things__books", Vector3.new(-17.0, 2.64, M.maxZ - 0.8), Vector3.new(0, 0, -1))
	prop("office__file_cabinets__file_cabinet_largest", Vector3.new(-12.75, 0, M.maxZ - 1.55), Vector3.new(0, 0, -1), { collide = true })
	prop("office__file_cabinets__file_cabinet_larger_open", Vector3.new(-4, 0, M.maxZ - 1.55), Vector3.new(0, 0, -1), { collide = true })
	prop("office__file_cabinets__file_cabinet_smaller_with_shelfs", Vector3.new(3.5, 0, M.maxZ - 1.2), Vector3.new(0, 0, -1), { collide = true })
	prop("office__book_things__file_binder_alt", Vector3.new(3.2, 3.7, M.maxZ - 1.2), Vector3.new(0, 0, -1))
	prop("office__book_things__file_binder_alt2", Vector3.new(3.6, 3.7, M.maxZ - 1.2), Vector3.new(0, 0, -1))
	prop("office__extras__whiteboard", Vector3.new(M.minX + 1.4, 0, 6), Vector3.new(1, 0, 0), { collide = true, scale = 0.78 })
	prop("office__extras__wall_clock", Vector3.new(4, 7.2, M.minZ + 0.13), Vector3.new(0, 0, 1))
	prop("classic64__blend__fire_extenguisher_case", Vector3.new(M.maxX - 0.4, 3.4, -3), Vector3.new(-1, 0, 0), { collide = true })
	prop("office__extras__water_cooler_bottle_attached", Vector3.new(M.maxX - 1, 0, 1.6), Vector3.new(-1, 0, 0), { collide = true, scale = 0.8 })
	prop("classic64__blend__door_brown_a", Vector3.new(-20.4, 0, M.maxZ - 0.1), Vector3.new(0, 0, -1), { scale = 1.0 })
	prop("classic64__blend__papers_envolope_redacted", Vector3.new(20.4, Layout.DESK_TOP, -11.2), Vector3.new(-1, 0, 1), { scale = 1.6 })
	prop("classic64__blend__panel_electrical_closed", Vector3.new(-30.66, 5.1, -4.9), Vector3.new(1, 0, 0), { scale = 2.2, collide = true })

	-- printer (simple shapes) on a cabinet by the south wall
	local P = Layout.PRINTER
	local printer = part("Printer", Vector3.new(2.2, 1.2, 1.8), CFrame.new(P + Vector3.new(0, 0.6, 0)), group("Interactive"), {
		color = Color3.fromRGB(190, 186, 170),
	})
	part("PrinterTray", Vector3.new(1.6, 0.1, 0.9), CFrame.new(P + Vector3.new(0, 1.25, -0.7)), group("Interactive"), { color = C.dark, collide = false })
	refs.printer = printer
	refs.printerLed = part("PrinterLed", Vector3.new(0.15, 0.15, 0.05), CFrame.new(P + Vector3.new(0.8, 0.9, -0.92)), group("Interactive"), {
		color = Color3.fromRGB(40, 60, 40),
		material = Enum.Material.Neon,
		collide = false,
	})
	prop("office__file_cabinets__file_cabinet_small", Vector3.new(P.X, 0, P.Z), Vector3.new(0, 0, -1), { collide = true, scale = 0.75 })

	-- notice board with the procedures (evidence against false instructions)
	local board = part("NoticeBoard", Vector3.new(4.2, 3.2, 0.15), CFrame.new(12.5, 5.6, M.minZ + 0.1), group("Interactive"), {
		color = Color3.fromRGB(140, 108, 76),
		collide = false,
	})
	refs.noticeBoards = { board }

	-- kitchenette: counter, coffee, fridge, bin. Nothing stored on the floor.
	local K = Layout.KITCHEN
	box("Counter", Vector3.new(K.minX, 0, K.minZ), Vector3.new(K.minX + 2.6, 3.1, K.maxZ - 2), group("Structure"), {
		color = Color3.fromRGB(170, 150, 120),
		surface = "wall_lower",
		tile = 4,
	})
	box("CounterTop", Vector3.new(K.minX, 3.05, K.minZ), Vector3.new(K.minX + 2.7, 3.15, K.maxZ - 2), group("Structure"), { color = C.trim, collide = false })
	prop("office__extras__coffee_machine", Vector3.new(K.minX + 1.2, 3.1, -9.5), Vector3.new(1, 0, 0), { scale = 0.23 })
	prop("office__extras__mug_alt3", Vector3.new(K.minX + 1.5, 3.1, -7.8), Vector3.new(1, 0, 0))
	prop("office__extras__mug_alt2", Vector3.new(K.minX + 1.2, 3.1, -7.3), Vector3.new(1, 0, 0))
	prop("cute3d__blend__fridge", Vector3.new(K.minX + 4.5, 0, K.minZ + 2.45), Vector3.new(0, 0, 1), { collide = true, pad = 0.2, scale = 0.8 })
	local trashPos = Layout.KITCHEN_TRASH
	prop("urban__litter__trashcan__trash_can", trashPos, Vector3.new(1, 0, 0), { collide = true, scale = 0.6 })
	refs.kitchenTrash = part("KitchenTrash", Vector3.new(2.6, 3.5, 2.4), CFrame.new(trashPos + Vector3.new(0, 1.75, 0)), group("Interactive"), {
		transparency = 1,
		collide = false,
	})

	-- lobby + time clock + front doors
	local L = Layout.LOBBY
	prop("office__couches__couch_pattern", Vector3.new(17.4, 0, 19.0), Vector3.new(-1, 0, 0), { collide = true, pad = 0.4 })
	prop("oldstuff__telephone", Vector3.new(8, 3.1, 21.6), Vector3.new(0, 0, -1))
	box("ReceptionDesk", Vector3.new(L.minX, 0, 20.4), Vector3.new(L.minX + 4.2, 3.1, 22.5), group("Structure"), {
		color = Color3.fromRGB(120, 90, 66),
		surface = "wall_lower",
		tile = 4,
	})
	box("ReceptionTop", Vector3.new(L.minX, 3.05, 20.3), Vector3.new(L.minX + 4.3, 3.15, 22.6), group("Structure"), { color = C.trim, collide = false })
	prop("office__extras__wall_clock", Vector3.new(13, 9.2, L.minZ + 1.13), Vector3.new(0, 0, 1))
	prop("classic64__blend__papers_log_1_stack", Vector3.new(7.4, 3.1, 21.0), Vector3.new(0, 0, -1))
	local tc = part("TimeClock", Vector3.new(0.7, 1.8, 1.4), CFrame.new(Layout.TIME_CLOCK), group("Interactive"), {
		color = Color3.fromRGB(196, 190, 170),
	})
	label(tc, Enum.NormalId.Right, "TIME CLOCK", Color3.fromRGB(30, 30, 30))
	part("CardRack", Vector3.new(0.2, 1.8, 1.2), CFrame.new(Layout.TIME_CLOCK + Vector3.new(0.1, -0.2, -1.6)), group("Interactive"), {
		color = Color3.fromRGB(120, 120, 120),
		collide = false,
	})
	refs.timeClock = tc
	local FD = Layout.FRONT_DOOR
	local half = (FD.maxX - FD.minX) / 2
	for i = 0, 1 do
		local x0 = FD.minX + i * half
		local door = part("FrontDoor" .. (i + 1), Vector3.new(half - 0.1, FD.height, 0.25), CFrame.new(x0 + half / 2, FD.height / 2, FD.z + 0.5), group("Interactive"), {
			color = C.glass,
			material = Enum.Material.SmoothPlastic,
			transparency = 0.5,
		})
		table.insert(refs.frontDoors, door)
		part("FrontDoorBar", Vector3.new(half - 0.6, 0.2, 0.2), CFrame.new(x0 + half / 2, 3.6, FD.z + 0.3), door, { color = C.metal, collide = false })
	end
	local exit = part("ExitSign", Vector3.new(1.8, 0.6, 0.15), CFrame.new(13, FD.height + 0.7, FD.z + 0.3), group("Interactive"), {
		color = Color3.fromRGB(120, 20, 20),
		material = Enum.Material.Neon,
		collide = false,
	})
	label(exit, Enum.NormalId.Front, "EXIT", Color3.new(1, 0.85, 0.85))
	refs.escapeZone = box("EscapeZone", Vector3.new(Layout.ESCAPE_ZONE.minX, 0, Layout.ESCAPE_ZONE.minZ), Vector3.new(Layout.ESCAPE_ZONE.maxX, 8, Layout.ESCAPE_ZONE.maxZ), group("Interactive"), {
		transparency = 1,
		collide = false,
	})

	-- utility hall: breakers, thermostat, heater, a pipe run and a duct
	local H = Layout.HALL
	local B = Layout.BREAKER
	local backing = part("BreakerBacking", Vector3.new(3.4, 2.4, 0.2), CFrame.new(B.panel + Vector3.new(0, 0, 0.1)), group("Interactive"), {
		color = Color3.fromRGB(80, 84, 88),
		surface = "metal_panel",
		tile = 3,
	})
	local header = part("BreakerHeader", Vector3.new(3.4, 0.45, 0.1), CFrame.new(B.panel + Vector3.new(0, 1.5, 0.15)), group("Interactive"), {
		color = Color3.fromRGB(214, 196, 86),
		collide = false,
	})
	label(header, Enum.NormalId.Back, "BREAKERS  - reset tripped switches -", Color3.fromRGB(20, 20, 20))
	for _, sw in B.switches do
		local s = part("Breaker_" .. sw.id, Vector3.new(0.45, 0.9, 0.3), CFrame.new(sw.pos), group("Interactive"), {
			color = Color3.fromRGB(40, 40, 40),
		})
		refs.breakerSwitches[sw.id] = s
		local lamp = part("BreakerLamp_" .. sw.id, Vector3.new(0.22, 0.22, 0.1), CFrame.new(sw.pos + Vector3.new(0, 0.75, 0)), group("Interactive"), {
			color = Color3.fromRGB(60, 255, 90),
			material = Enum.Material.Neon,
			collide = false,
		})
		refs.breakerLamps[sw.id] = lamp
		local tag = part("BreakerTag_" .. sw.id, Vector3.new(0.75, 0.3, 0.05), CFrame.new(sw.pos + Vector3.new(0, -0.72, 0.1)), group("Interactive"), {
			color = Color3.fromRGB(240, 240, 230),
			collide = false,
		})
		label(tag, Enum.NormalId.Back, sw.label, Color3.fromRGB(10, 10, 10))
	end
	local _ = backing
	prop("classic64__blend__panel_thermostat", Layout.THERMOSTAT, Vector3.new(0, 0, -1), { scale = 2.4 })
	refs.thermostat = part("ThermostatPrompt", Vector3.new(1, 1, 0.4), CFrame.new(Layout.THERMOSTAT + Vector3.new(0, 0.2, -0.2)), group("Interactive"), {
		transparency = 1,
		collide = false,
	})
	prop("classic64__blend__panel_heater", Vector3.new(32.5, 0, H.maxZ - 0.55), Vector3.new(0, 0, -1), { scale = 1.6, collide = true })
	prop("classic64__blend__panel_electric", Vector3.new(24.2, 3.2, H.minZ + 0.52), Vector3.new(0, 0, 1), { scale = 1.4, collide = true })
	prop("classic64__blend__electrical_junctionbox_small", Vector3.new(31.4, 5.2, H.minZ + 0.1), Vector3.new(0, 0, 1), { scale = 3 })
-- (ducts and pipes removed: the source models are 3.5+ studs tall and pierce the 9-stud hall ceiling)

	-- procedures notice at the rear door
	local rearNotice = part("RearDoorNotice", Vector3.new(0.1, 1.6, 1.3), CFrame.new(35.85, 4.6, 8.3), group("Interactive"), {
		color = Color3.fromRGB(235, 230, 205),
		collide = false,
	})
	label(rearNotice, Enum.NormalId.Left, "KEEP THIS DOOR LATCHED AFTER 22:00 - FACILITIES", Color3.fromRGB(150, 20, 20))
	table.insert(refs.noticeBoards, rearNotice)
end

local function buildRearDoor(refs: Refs)
	local RD = Layout.REAR_DOOR
	local width = RD.maxZ - RD.minZ
	local hinge = CFrame.new(RD.x + 0.5, 0, RD.minZ)
	refs.rearDoorHinge = hinge
	local door = part("RearDoor", Vector3.new(0.3, RD.height - 0.05, width - 0.1), hinge * CFrame.new(0, RD.height / 2, width / 2), group("Interactive"), {
		color = Color3.fromRGB(96, 100, 104),
		surface = "metal_door",
		tile = 4,
	})
	part("PushBar", Vector3.new(0.25, 0.25, width - 0.8), door.CFrame * CFrame.new(-0.25, -0.2, 0), door, {
		color = Color3.fromRGB(170, 170, 170),
		collide = false,
	})
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = door
	weld.Part1 = door:FindFirstChild("PushBar") :: BasePart
	weld.Parent = door
	refs.rearDoor = door
	refs.doorPromptPart = part("RearDoorPrompt", Vector3.new(1.2, 1.2, 1.2), CFrame.new(RD.x - 0.8, 3.6, (RD.minZ + RD.maxZ) / 2), group("Interactive"), {
		transparency = 1,
		collide = false,
	})
	local exitSign = part("RearExitSign", Vector3.new(0.15, 0.5, 1.6), CFrame.new(RD.x - 0.1, RD.height + 0.8, (RD.minZ + RD.maxZ) / 2), group("Interactive"), {
		color = Color3.fromRGB(120, 20, 20),
		material = Enum.Material.Neon,
		collide = false,
	})
	label(exitSign, Enum.NormalId.Left, "EXIT", Color3.new(1, 0.85, 0.85))
end

local function buildAlley(refs: Refs)
	local A = Layout.ALLEY
	local D = Layout.DUMPSTER
	prop("urban__litter__dumpsters__dumpster_lid_closed", D, Vector3.new(1, 0, 0), { collide = true, pad = 0.2, scale = 0.7 })
	refs.dumpster = part("DumpsterPrompt", Vector3.new(7, 6, 3), CFrame.new(D + Vector3.new(0, 3, -2.4)), group("Interactive"), {
		transparency = 1,
		collide = false,
	})
	prop("urban__litter__trash__trashbag_2_white", Vector3.new(54.6, 0, 14.6), Vector3.new(1, 0, -1), { scale = 0.5 })
	prop("urban__litter__metal_trashcan__metaltrashcan_closed", Vector3.new(38.6, 0, 14.4), Vector3.new(0, 0, -1), { collide = true })
	prop("urban__litter__metal_trashcan__metaltrashcan_overflowing", Vector3.new(39.2, 0, -4.6), Vector3.new(0, 0, 1), { collide = true, scale = 0.75 })
	prop("classic64__blend__wood_pallet", Vector3.new(59.2, 0, 13.2), Vector3.new(0, 0, 1), { scale = 0.77 })
	prop("oldstuff__barrel", Vector3.new(62.5, 0, -4), Vector3.new(0, 0, 1), { collide = true })
	prop("classic64__blend__manhole_cover", Vector3.new(50, 0.02, 5), Vector3.new(0, 0, 1), { scale = 0.4 })
	for _, z in { -2, 12 } do
		prop("classic64__blend__yellow_post", Vector3.new(37.6, 0, z), Vector3.new(0, 0, 1), { collide = true })
	end
	prop("urban__traffic_lights__street_light", Vector3.new(45, 0, -4.7), Vector3.new(0, 0, 1), { collide = true })
	pointLight("alley", Vector3.new(45, 21.5, -4), C.cold, 34, 1.0)
	prop("urban__cones_barriers__bollards__concrete_retro_bollard_light", Vector3.new(38.5, 0, 9.5), Vector3.new(-1, 0, 0), { collide = true })
	pointLight("alley", Vector3.new(38.5, 4.2, 9.5), C.amber, 9, 0.5)
	-- broken wooden hoarding at the alley mouth: the figure comes from beyond
	prop("urban__fences__plackard_wall__plackard_closed", Vector3.new(64.5, 0, -2.75), Vector3.new(-1, 0, 0), { collide = true, scale = 0.6 })
	prop("urban__fences__plackard_wall__plackard_broken", Vector3.new(64.5, 0, 12.75), Vector3.new(-1, 0, 0), { collide = true, scale = 0.6 })
	-- outdoor street (front) dressing
	prop("urban__traffic_lights__street_light", Vector3.new(18.2, 0, 31), Vector3.new(0, 0, -1), { collide = true })
	pointLight("exterior", Vector3.new(19, 21.5, 30), C.cold, 30, 0.9)
	prop("urban__litter__metal_trashcan__metaltrashcan_closed", Vector3.new(8, 0, 25.9), Vector3.new(0, 0, -1), { collide = true })

	-- the figure (dynamic mesh, welded to the NPC root by the Threat system)
	refs.threatAnchorKey = "characters__male__character_04"

	-- missing crew silhouettes for late disturbances and the ending (hidden by default)
	local crew: { { key: string, pos: Vector3 } } = {
		{ key = "characters__male__character_01", pos = Vector3.new(-10, 0, -22) },
		{ key = "characters__male__character_05", pos = Vector3.new(2, 0, -22.5) },
	}
	for i, spec in crew do
		local fig = prop(spec.key, spec.pos, Vector3.new(0, 0, 1), { dynamic = true })
		if fig then
			fig:SetAttribute("ArtHidden", true)
			fig.Name = "CrewFigure" .. i
			table.insert(refs.crewFigures, fig)
		end
	end
	local _ = A
end

local function buildLights(refs: Refs)
	local ceil = Layout.CEILING
	for _, p in Layout.LIGHTS.main do
		fluorescent("main", p, ceil)
	end
	for _, p in Layout.LIGHTS.kitchen do
		fluorescent("kitchen", p, ceil - 1, Color3.fromRGB(240, 232, 212), 0.7)
	end
	for _, p in Layout.LIGHTS.lobby do
		fluorescent("lobby", p, ceil, Color3.fromRGB(236, 232, 220), 0.7)
	end
	for _, p in Layout.LIGHTS.hall do
		local bulb = part("Bulb", Vector3.new(0.5, 0.6, 0.5), CFrame.new(p.X, 8.4, p.Z), group("Lights"), {
			color = Color3.fromRGB(230, 200, 140),
			material = Enum.Material.Neon,
			collide = false,
		})
		local l = Instance.new("PointLight")
		l.Color = C.amber
		l.Range = 12
		l.Brightness = 0.8
		l.Shadows = true
		l.Parent = bulb
		lightGroups.hall = lightGroups.hall or {}
		table.insert(lightGroups.hall, l)
		fixtures.hall = fixtures.hall or {}
		table.insert(fixtures.hall, bulb)
	end
	-- battery emergency lights: dim red, always on during a blackout
	local emergency: { Light } = {}
	for _, p in {
		Vector3.new(13, 7.8, 13.6),
		Vector3.new(28, 7.8, 6),
		Vector3.new(0, 7.8, -13.4),
		Vector3.new(-20, 7.8, 0),
		Vector3.new(-26, 7.5, -8),
		Vector3.new(16, 7.8, -7),
	} do
		local l = pointLight("emergency", p, Color3.fromRGB(196, 110, 96), 18, 0)
		table.insert(emergency, l)
	end
	refs.emergencyLights = emergency
	refs.deskLamps = lightGroups.lamps or {}
	refs.lights = lightGroups
	refs.fixtures = fixtures
end

local function collisionGroups()
	local PhysicsService = game:GetService("PhysicsService")
	for _, g in { "PlayerLimit", "Figure" } do
		if not PhysicsService:IsCollisionGroupRegistered(g) then
			PhysicsService:RegisterCollisionGroup(g)
		end
	end
	PhysicsService:CollisionGroupSetCollidable("PlayerLimit", "Figure", false)
end

function MapBuilder.init()
	collisionGroups()
	local existing = workspace:FindFirstChild("Map")
	if existing then
		existing:Destroy()
	end
	root = Instance.new("Folder")
	root.Name = "Map"
	groups = {}
	lightGroups = {}
	fixtures = {}

	local refs: Refs = {
		map = root,
		interactive = group("Interactive"),
		sourcePCs = {},
		sourceLeds = {},
		sourceScreens = {},
		drivePlace = {},
		stagingSlots = {},
		erasedSlots = {},
		recoveryRack = (nil :: any) :: BasePart,
		dock = (nil :: any) :: BasePart,
		dockLed = (nil :: any) :: BasePart,
		seat = (nil :: any) :: Seat,
		seatPromptPart = (nil :: any) :: BasePart,
		monitorScreen = (nil :: any) :: BasePart,
		breakerSwitches = {},
		breakerLamps = {},
		rearDoor = (nil :: any) :: BasePart,
		rearDoorHinge = CFrame.identity,
		doorLight = (nil :: any) :: BasePart,
		doorPromptPart = (nil :: any) :: BasePart,
		frontDoors = {},
		timeClock = (nil :: any) :: BasePart,
		kitchenTrash = (nil :: any) :: BasePart,
		dumpster = (nil :: any) :: BasePart,
		thermostat = (nil :: any) :: BasePart,
		printer = (nil :: any) :: BasePart,
		printerLed = (nil :: any) :: BasePart,
		outbox = (nil :: any) :: BasePart,
		threatAnchorKey = "",
		shiftChair = (nil :: any) :: BasePart,
		lights = {},
		emergencyLights = {},
		deskLamps = {},
		workstationLamp = (nil :: any) :: Light,
		fixtures = {},
		noticeBoards = {},
		crewFigures = {},
		escapeZone = (nil :: any) :: BasePart,
	}
	MapBuilder.refs = refs

	buildStructure()
	buildDesks(refs)
	buildWorkstation(refs)
	buildRooms(refs)
	buildRearDoor(refs)
	buildAlley(refs)
	buildLights(refs)

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "OfficeSpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(6, 0.2, 4)
	spawn.CFrame = CFrame.new(12, 0.1, 9)
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Parent = root

	root.Parent = workspace
	workspace:SetAttribute("MapReady", true)
end

return MapBuilder
