--!strict
-- The figure in the outdated company uniform. Server-controlled NPC:
-- the server alone moves it and decides catches. Behaviours:
--   approach  alley end -> rear door; repelled if the door is latched in time
--   hunt      inside the office for a limited time, then leaves
--   chase     alley encounter after a trash trip (head start, stops at door)
--   pursue    finale: slow pursuit while the team clocks out
--   peek      harmless glimpse (outside the windows / alley end)
-- Navigation uses PathfindingService with straight-line fallback; the map is
-- small and open so paths are short and reliable.

local PathfindingService = game:GetService("PathfindingService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Layout = require(ReplicatedStorage.Shared.Layout)
local Server = script.Parent.Parent
local Guard = require(Server.Util.Guard)
local GameState = require(script.Parent.GameState)
local MapBuilder = require(script.Parent.MapBuilder)
local Doors = require(script.Parent.Doors)
local PlayerStatus = require(script.Parent.PlayerStatus)

local Threat = {}

type Mode = "idle" | "approach" | "waitDoor" | "hunt" | "leave" | "chase" | "pursue" | "peek"

local model: Model
local root: BasePart
local humanoid: Humanoid
local visual: BasePart
local mode: Mode = "idle"
local token = 0 -- bumps whenever a behaviour is replaced, so stale loops exit
local pathBusy = false -- only one path follower may steer the figure

local function setVisible(v: boolean)
	visual:SetAttribute("ArtHidden", not v)
	model:SetAttribute("Active", v)
end

local function hide()
	token += 1
	mode = "idle"
	humanoid:MoveTo(root.Position)
	root.Anchored = true
	root.CFrame = CFrame.new(Layout.THREAT_HIDE)
	setVisible(false)
	GameState.setThreat("figure", nil)
	model:SetAttribute("Mode", "idle")
end

local function placeAt(pos: Vector3, lookAt: Vector3?)
	root.Anchored = true
	local p = pos + Vector3.new(0, 3, 0)
	root.CFrame = if lookAt then CFrame.lookAt(p, Vector3.new(lookAt.X, p.Y, lookAt.Z)) else CFrame.new(p)
	root.Anchored = false
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
	setVisible(true)
end

local function setMode(m: Mode, speed: number)
	mode = m
	humanoid.WalkSpeed = speed
	model:SetAttribute("Mode", m)
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Walk to a point. Returns true on arrival, false if interrupted/timed out.
local walkTo: (target: Vector3, myToken: number, timeout: number, usePath: boolean?) -> boolean
walkTo = function(target: Vector3, myToken: number, timeout: number, usePath: boolean?): boolean
	local deadline = os.clock() + timeout
	local waypoints: { Vector3 } = { target }
	if usePath then
		local path = PathfindingService:CreatePath({ AgentRadius = 1.4, AgentHeight = 6, AgentCanJump = false, WaypointSpacing = 4 })
		local ok = pcall(function()
			path:ComputeAsync(root.Position, target)
		end)
		if ok and path.Status == Enum.PathStatus.Success then
			waypoints = {}
			for _, w in path:GetWaypoints() do
				table.insert(waypoints, w.Position)
			end
		end
	end
	local lastPos = root.Position
	local lastMove = os.clock()
	for _, wp in waypoints do
		while os.clock() < deadline do
			if token ~= myToken then
				return false
			end
			humanoid:MoveTo(wp)
			if (flat(root.Position) - flat(wp)).Magnitude < 2 then
				break
			end
			-- stuck on geometry: re-plan with pathfinding (once per call)
			if humanoid.WalkSpeed > 0 and (root.Position - lastPos).Magnitude > 0.5 then
				lastPos = root.Position
				lastMove = os.clock()
			elseif humanoid.WalkSpeed > 0 and os.clock() - lastMove > 1.5 and not usePath then
				return walkTo(target, myToken, math.max(1, deadline - os.clock()), true)
			end
			task.wait(0.1)
		end
	end
	return token == myToken and (flat(root.Position) - flat(target)).Magnitude < 3
end

local function tryCatch(): Player?
	for _, p in PlayerStatus.standing() do
		local r = Guard.rootOf(p)
		if r and (r.Position - root.Position).Magnitude <= Config.THREAT.catchDistance then
			PlayerStatus.down(p, "the figure")
			return p
		end
	end
	return nil
end

local function nearestTarget(indoorsOnly: boolean): (Player?, BasePart?)
	local best: Player?, bestRoot: BasePart?, bestD = nil, nil, math.huge
	for _, p in PlayerStatus.standing() do
		local r = Guard.rootOf(p)
		if r and (not indoorsOnly or Layout.isIndoors(r.Position) or Layout.regionOf(r.Position) == "Utility hall") then
			local d = (r.Position - root.Position).Magnitude
			if d < bestD then
				best, bestRoot, bestD = p, r, d
			end
		end
	end
	return best, bestRoot
end

function Threat.busy(): boolean
	return mode ~= "idle"
end

function Threat.mode(): string
	return mode
end

function Threat.position(): Vector3?
	return if mode == "idle" then nil else root.Position
end

function Threat.despawn()
	hide()
	Doors.setLocked(false)
end

-- Leave via the rear door and vanish. The door is left ajar behind it.
local function leaveBuilding(myToken: number, onDone: (() -> ())?)
	setMode("leave", Config.THREAT.walkSpeed + 2)
	GameState.setThreat("figure", "The figure is leaving", true, "Office")
	local route = Layout.THREAT_ROUTE
	walkTo(route[5], myToken, 20, true)
	for i = 4, 1, -1 do
		if not walkTo(route[i], myToken, 12) then
			break
		end
	end
	if token == myToken then
		hide()
		if Doors.state() == "Latched" then
			Doors.set("Ajar")
		end
		if onDone then
			onDone()
		end
	end
end

-- Hunt inside for `seconds`, chasing the nearest standing player.
function Threat.hunt(seconds: number, onDone: (() -> ())?)
	token += 1
	local myToken = token
	local solo = GameState.isSolo()
	setMode("hunt", if solo then Config.THREAT.huntSpeed.solo else Config.THREAT.huntSpeed.coop)
	GameState.setThreat("figure", "Someone is inside the office", true, "Office")
	GameState.fx("FigureInside", nil)
	task.spawn(function()
		local endAt = os.clock() + seconds
		local lastPath = 0
		local caught = false
		while token == myToken and os.clock() < endAt do
			local target, tRoot = nearestTarget(true)
			if tRoot then
				local d = (tRoot.Position - root.Position).Magnitude
				if d < 14 then
					humanoid:MoveTo(tRoot.Position)
				elseif os.clock() - lastPath > 1 then
					lastPath = os.clock()
					if not pathBusy then
						pathBusy = true
						task.spawn(function()
							walkTo(tRoot.Position, myToken, 1.2, true)
							pathBusy = false
						end)
					end
				end
			end
			if tryCatch() then
				caught = true
				break -- one catch per visit: gives teammates a fair rescue window
			end
			task.wait(0.1)
			local _ = target
		end
		if token == myToken then
			if caught then
				task.wait(1.2)
			end
			leaveBuilding(myToken, onDone)
		end
	end)
end

-- Walk from the alley end to the rear door. If the door is latched by the
-- time it arrives, it waits, knocks and retreats. Otherwise it comes in.
function Threat.approach(callbacks: { onRepelled: (() -> ())?, onEntered: (() -> ())?, onDone: (() -> ())? })
	token += 1
	local myToken = token
	local route = Layout.THREAT_ROUTE
	placeAt(route[1], route[2])
	setMode("approach", Config.THREAT.walkSpeed)
	GameState.setThreat("figure", "Someone is walking up the alley", true, "Alley")
	GameState.fx("FigureApproach", nil)
	task.spawn(function()
		local ok = walkTo(route[2], myToken, 10)
		if ok then
			setMode("approach", 0)
			task.wait(Config.THREAT.approachPause)
			setMode("approach", Config.THREAT.approachSpeed)
		end
		ok = ok and token == myToken and walkTo(Layout.THREAT_DOOR_STOP, myToken, Config.EVENTS.DoorUnlatch.approachSeconds + 10)
		if token ~= myToken then
			return
		end
		if not ok or Doors.state() == "Latched" then
			setMode("waitDoor", 0)
			GameState.fx("DoorKnock", nil)
			task.wait(3.5)
			if token ~= myToken then
				return
			end
			if Doors.state() == "Latched" then
				setMode("leave", Config.THREAT.walkSpeed)
				GameState.setThreat("figure", "The figure is walking away", false, "Alley")
				walkTo(route[1], myToken, 14)
				if token == myToken then
					hide()
					if callbacks.onRepelled then
						callbacks.onRepelled()
					end
					if callbacks.onDone then
						callbacks.onDone()
					end
				end
				return
			end
		end
		-- door is open: come in
		if Doors.state() ~= "Latched" then
			Doors.set("Open")
			Doors.setLocked(true)
			walkTo(route[5], myToken, 6)
			Doors.setLocked(false)
			if token ~= myToken then
				return
			end
			if callbacks.onEntered then
				callbacks.onEntered()
			end
			local solo = GameState.isSolo()
			Threat.hunt(if solo then Config.THREAT.huntSeconds.solo else Config.THREAT.huntSeconds.coop, callbacks.onDone)
		end
	end)
end

-- Alley encounter: visible at the alley end, head start, then chase. It never
-- enters the building during this encounter.
function Threat.chase(target: Player, first: boolean, onDone: ((caught: boolean) -> ())?)
	token += 1
	local myToken = token
	local route = Layout.THREAT_ROUTE
	placeAt(route[2], Layout.DUMPSTER)
	setMode("chase", 0)
	GameState.setThreat("figure", "RUN - back inside!", true, "Alley")
	GameState.fx("ChaseStart", { target = target.UserId, headStart = Config.THREAT.headStartSeconds })
	task.spawn(function()
		task.wait(Config.THREAT.headStartSeconds)
		if token ~= myToken then
			return
		end
		setMode("chase", if first then Config.THREAT.chaseSpeed.first else Config.THREAT.chaseSpeed.normal)
		local caught = false
		local giveUpAt = os.clock() + 25
		while token == myToken and os.clock() < giveUpAt do
			local r = Guard.rootOf(target)
			if not r or target:GetAttribute("Downed") == true then
				break
			end
			if r.Position.X < Layout.REAR_DOOR.x - 0.5 then
				break -- target made it inside
			end
			local goal = r.Position
			if goal.X < Layout.THREAT_DOOR_STOP.X then
				goal = Layout.THREAT_DOOR_STOP
			end
			humanoid:MoveTo(goal)
			if (r.Position - root.Position).Magnitude <= Config.THREAT.catchDistance then
				PlayerStatus.down(target, "caught in the alley")
				caught = true
				break
			end
			task.wait(0.1)
		end
		if token ~= myToken then
			return
		end
		setMode("leave", Config.THREAT.walkSpeed)
		GameState.setThreat("figure", nil)
		task.wait(1.5)
		walkTo(route[1], myToken, 12)
		if token == myToken then
			hide()
			if onDone then
				onDone(caught)
			end
		end
	end)
end

-- Finale: a slow, relentless pursuit through the office while the team
-- clocks out. Slower than walking speed, so it only catches the careless.
function Threat.pursue()
	token += 1
	local myToken = token
	placeAt(Layout.THREAT_FINALE_SPAWN, Vector3.new(0, 0, 0))
	setMode("pursue", Config.THREAT.clockOutSpeed)
	GameState.setThreat("figure", "It's inside. Get to the time clock.", true, "Office")
	GameState.fx("FigureInside", { finale = true })
	task.spawn(function()
		local lastPath = 0
		while token == myToken do
			local _, tRoot = nearestTarget(true)
			if tRoot then
				if (tRoot.Position - root.Position).Magnitude < 12 then
					humanoid:MoveTo(tRoot.Position)
				elseif os.clock() - lastPath > 1.2 then
					lastPath = os.clock()
					if not pathBusy then
						pathBusy = true
						task.spawn(function()
							walkTo(tRoot.Position, myToken, 1.3, true)
							pathBusy = false
						end)
					end
				end
			end
			tryCatch()
			task.wait(0.15)
		end
	end)
end

-- Harmless glimpse: stands somewhere visible for a moment, then gone.
function Threat.peek(where: "window" | "alley", seconds: number)
	if mode ~= "idle" then
		return
	end
	token += 1
	local myToken = token
	local pos = if where == "window" then Vector3.new(Layout.WINDOWS_X[math.random(1, #Layout.WINDOWS_X)], 0, -19) else Layout.THREAT_ROUTE[1]
	placeAt(pos, if where == "window" then Vector3.new(pos.X, 0, 0) else Layout.THREAT_DOOR_STOP)
	root.Anchored = true
	setMode("peek", 0)
	GameState.fx("FigurePeek", { where = where })
	task.delay(seconds, function()
		if token == myToken then
			hide()
		end
	end)
end

function Threat.init()
	model = Instance.new("Model")
	model.Name = "Figure"
	root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Transparency = 1
	root.CanCollide = false
	root.CanQuery = false
	root.Anchored = true
	root.CFrame = CFrame.new(Layout.THREAT_HIDE)
	root.Parent = model
	-- collision body so it cannot pass through walls/desks
	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(1.8, 4.6, 1.2)
	body.Transparency = 1
	body.CanCollide = true
	body.Massless = true
	body.CFrame = root.CFrame * CFrame.new(0, -0.6, 0)
	local w = Instance.new("WeldConstraint")
	w.Part0 = root
	w.Part1 = body
	w.Parent = body
	body.Parent = model
	humanoid = Instance.new("Humanoid")
	humanoid.HipHeight = 2
	humanoid.WalkSpeed = Config.THREAT.walkSpeed
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.MaxHealth = math.huge
	humanoid.Health = math.huge
	humanoid.BreakJointsOnDeath = false
	humanoid.Parent = model
	model.PrimaryPart = root
	-- the figure ignores the invisible player boundary at the alley mouth
	root.CollisionGroup = "Figure"
	body.CollisionGroup = "Figure"

	-- visual mesh (built by clients from the character library)
	visual = Instance.new("Part")
	visual.Name = "FigureVisual"
	visual.Size = Vector3.new(0.2, 0.2, 0.2)
	visual.Transparency = 1
	visual.CanCollide = false
	visual.CanQuery = false
	visual.Massless = true
	-- character meshes face -Z natively, which is the root's LookVector
	visual.CFrame = root.CFrame * CFrame.new(0, -3, 0)
	visual:SetAttribute("ArtKey", MapBuilder.refs.threatAnchorKey)
	visual:SetAttribute("ArtDynamic", true)
	visual:SetAttribute("ArtHidden", true)
	local vw = Instance.new("WeldConstraint")
	vw.Part0 = root
	vw.Part1 = visual
	vw.Parent = visual
	visual.Anchored = false
	visual.Parent = model
	CollectionService:AddTag(visual, "ArtAnchor")
	-- eerie local light the clients can see from a distance
	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 120, 90)
	glow.Range = 7
	glow.Brightness = 0.35
	glow.Parent = root
	model:SetAttribute("Active", false)
	model.Parent = workspace

	GameState.RoundReset:Connect(Threat.despawn)
end

return Threat
