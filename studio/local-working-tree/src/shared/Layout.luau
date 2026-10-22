--!strict
-- Map layout: every coordinate in the office lives here so the server map
-- builder, the NPC route and the client camera agree. Units are studs,
-- floor at y = 0. +X = east, -Z = north.
--
--   kitchenette |        MAIN ROOM (7 desks)        | utility hall | alley
--               |  [workstation in NE corner]       |  breaker     | dumpster
--                         lobby + time clock (south)

local Layout = {}

Layout.CEILING = 10.5
Layout.WALL = 1

Layout.MAIN = { minX = -22, maxX = 22, minZ = -14, maxZ = 14 }
Layout.KITCHEN = { minX = -31, maxX = -22, minZ = -13, maxZ = -4 }
Layout.LOBBY = { minX = 6, maxX = 20, minZ = 14, maxZ = 23 }
Layout.HALL = { minX = 22, maxX = 36, minZ = 3, maxZ = 9 }
Layout.ALLEY = { minX = 36, maxX = 66, minZ = -6, maxZ = 16 }
Layout.STREET = { minX = 6, maxX = 22, minZ = 23, maxZ = 34 } -- outside the front door (escape)

-- Openings (gaps in walls)
Layout.KITCHEN_GAP = { minZ = -12, maxZ = -5.5 } -- on the x = -22 wall
Layout.LOBBY_GAP = { minX = 9, maxX = 15 } -- on the z = 14 wall
Layout.HALL_GAP = { minZ = 3, maxZ = 9 } -- the hall opens fully onto the room
Layout.REAR_DOOR = { x = 36, minZ = 4.5, maxZ = 7.5, height = 7 }
Layout.FRONT_DOOR = { z = 23, minX = 11, maxX = 15, height = 7.5 }
Layout.WINDOWS_X = { -14, -4, 6 } -- north wall windows (centres)

Layout.SPAWN = CFrame.new(12, 3, 9) * CFrame.Angles(0, 0, 0)

-- Desks: front = direction from the desk centre toward where the user sits.
export type DeskDef = {
	index: number,
	pos: Vector3,
	front: Vector3,
	art: string,
	chair: string,
}

Layout.DESKS = {
	{ index = 1, pos = Vector3.new(-14, 0, -2.6), front = Vector3.new(0, 0, -1), art = "office__desks__desk2", chair = "office__chairs__office_chair_black" },
	{ index = 2, pos = Vector3.new(-5.6, 0, -2.6), front = Vector3.new(0, 0, -1), art = "office__desks__desk2_alt", chair = "office__chairs__office_chair_grey" },
	{ index = 3, pos = Vector3.new(2.8, 0, -2.6), front = Vector3.new(0, 0, -1), art = "office__desks__desk2_alt2", chair = "office__chairs__office_chair_blue" },
	{ index = 4, pos = Vector3.new(-14, 0, 2.6), front = Vector3.new(0, 0, 1), art = "office__desks__desk2_alt3", chair = "office__chairs__office_chair_grey_alt" },
	{ index = 5, pos = Vector3.new(-5.6, 0, 2.6), front = Vector3.new(0, 0, 1), art = "office__desks__desk2_alt4", chair = "office__chairs__office_chair_black_alt" },
	{ index = 6, pos = Vector3.new(2.8, 0, 2.6), front = Vector3.new(0, 0, 1), art = "office__desks__desk2", chair = "office__chairs__office_chair_blue_alt" },
} :: { DeskDef }

Layout.DESK_SIZE = Vector3.new(7.7, 3.1, 3.8)
Layout.DESK_TOP = 3.1

-- Main workstation (corner desk, NE corner). The operator faces the corner,
-- so the room is behind them: comfort versus awareness.
Layout.WORKSTATION = {
	desk = Vector3.new(18.15, 0, -10.15),
	monitor = Vector3.new(19.7, 3.1, -11.7),
	facing = Vector3.new(1, 0, -1).Unit, -- direction the seated operator looks
	chair = Vector3.new(16.6, 0, -8.6),
	dock = Vector3.new(21.1, 3.1, -8.6),
	lamp = Vector3.new(17.0, 3.1, -13.0),
}

-- Drive rack beside the workstation (staging + recovery + erased tray)
Layout.RACK = {
	pos = Vector3.new(10.4, 0, -12.7),
	front = Vector3.new(0, 0, 1),
	stagingY = 3.72,
	erasedY = 1.95,
	slotX0 = 8.55,
	slotDX = 0.74,
	slotZ = -12.6,
}

Layout.BREAKER = {
	panel = Vector3.new(29, 4.6, 3.15),
	switches = {
		{ id = "MAIN", label = "MAIN", pos = Vector3.new(28.2, 4.6, 3.45) },
		{ id = "LIGHTS", label = "OFFICE LIGHTS", pos = Vector3.new(29.0, 4.6, 3.45) },
		{ id = "WORKSTATION", label = "WORKSTATION", pos = Vector3.new(29.8, 4.6, 3.45) },
	},
}

Layout.THERMOSTAT = Vector3.new(25, 4.6, 8.9)
Layout.DOOR_LIGHT = Vector3.new(22.4, 8.2, 6)
Layout.TIME_CLOCK = Vector3.new(6.25, 4.2, 18.5)
Layout.KITCHEN_TRASH = Vector3.new(-23.6, 0, -6.2)
Layout.DUMPSTER = Vector3.new(47, 0, 13.4)
Layout.PRINTER = Vector3.new(-9, 3.6, 13.1)
Layout.OUTBOX = Vector3.new(17.5, 3.1, -6.9) -- tray on the workstation desk edge
Layout.ESCAPE_ZONE = { minX = 8, maxX = 18, minZ = 26, maxZ = 33 }

-- NPC route from the dark end of the alley to the office.
Layout.THREAT_ROUTE = {
	Vector3.new(79, 0, 6), -- deep in the dark beyond the hoarding
	Vector3.new(62, 0, 6), -- alley mouth: it stops here and stares
	Vector3.new(44, 0, 6),
	Vector3.new(38.5, 0, 6),
	Vector3.new(34, 0, 6),
	Vector3.new(27, 0, 6),
	Vector3.new(20, 0, 6),
}
Layout.THREAT_DOOR_STOP = Vector3.new(39.2, 0, 6) -- where the figure waits if the door is latched
Layout.THREAT_HIDE = Vector3.new(80, -50, 6)
Layout.THREAT_FINALE_SPAWN = Vector3.new(-27, 0, -8)

Layout.LIGHTS = {
	main = {
		Vector3.new(-14, 0, -8),
		Vector3.new(-14, 0, 8),
		Vector3.new(-4, 0, -8),
		Vector3.new(-4, 0, 8),
		Vector3.new(6, 0, -8),
		Vector3.new(6, 0, 8),
		Vector3.new(16, 0, 0),
		Vector3.new(16, 0, 9),
	},
	kitchen = { Vector3.new(-26.5, 0, -8.5) },
	lobby = { Vector3.new(13, 0, 18.5) },
	hall = { Vector3.new(26, 0, 6), Vector3.new(32.5, 0, 6) },
}

-- Region queries -------------------------------------------------------------

local function inside(b: { minX: number, maxX: number, minZ: number, maxZ: number }, p: Vector3): boolean
	return p.X >= b.minX and p.X <= b.maxX and p.Z >= b.minZ and p.Z <= b.maxZ
end

function Layout.regionOf(p: Vector3): string
	if inside(Layout.MAIN, p) then
		return "Office"
	elseif inside(Layout.KITCHEN, p) then
		return "Kitchenette"
	elseif inside(Layout.LOBBY, p) then
		return "Lobby"
	elseif inside(Layout.HALL, p) then
		return "Utility hall"
	elseif inside(Layout.ALLEY, p) then
		return "Alley"
	elseif inside(Layout.STREET, p) then
		return "Street"
	end
	return "Outside"
end

function Layout.isIndoors(p: Vector3): boolean
	local r = Layout.regionOf(p)
	return r == "Office" or r == "Kitchenette" or r == "Lobby" or r == "Utility hall"
end

function Layout.inMap(p: Vector3): boolean
	return p.Y > -20 and p.Y < 60 and Layout.regionOf(p) ~= "Outside"
end

-- CFrame that turns a model whose native front is +Z to face `front`.
function Layout.facing(pos: Vector3, front: Vector3, yawOffsetDeg: number?): CFrame
	local yaw = math.atan2(front.X, front.Z) + math.rad(yawOffsetDeg or 0)
	return CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
end

return Layout
