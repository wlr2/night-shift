--!nocheck
-- Engine emulation for the smoke harness: the DataModel, client services,
-- the local player and character, the camera and the per-frame step.
-- Everything here is a stand-in for engine behaviour Lune does not provide;
-- each piece is deliberately small and documented in tools/smoke/README.md.

local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local Api = require("./api")
local Rt = require("./rt")
local Sched = require("./sched")
local Layout = require("./layout")

local V2, V3, CF, UD2, C3 = roblox.Vector2, roblox.Vector3, roblox.CFrame, roblox.UDim2, roblox.Color3
local recs = Rt.recs
local E = Rt.Enum

local World = {}
World.opts = { editables = true, cameraScripts = true, studio = false }
World.remoteLog = {} :: { any }
World.serverHandlers = {} :: { [string]: (...any) -> ...any }
World.cas = {} :: { [string]: any }
World.renderBindings = {} :: { any }
World.mouse = V2.new(683, 384)
World.lastInputType = nil
World.coreCalls = {} :: { any }
World.raycasts = 0

local function P(p: any, key: string): any
	return p[key]
end
local _ = P

local function rec(p: any): any
	return recs[p]
end

local function selfRec(self: any, name: string): any
	return Rt.selfRec(self, name)
end

local function service(name: string): any
	return World.services[name]
end

-------------------------------------------------------------------------------
-- defaults Lune lacks (or differ from what Instance.new gives in Roblox)

local DC = Rt.DefaultsByClass
local DP = Rt.DefaultsByProp
local function dflt(class: string, key: string, value: any)
	DC[class] = DC[class] or {}
	DC[class][key] = value
end

function World.registerDefaults()
	for _, cls in { "TextLabel", "TextButton", "TextBox" } do
		dflt(cls, "TextSize", 14) -- Roblox Instance.new gives 14 (Lune's file default is 8)
		dflt(cls, "Font", E.Font.Legacy)
	end
	dflt("TextButton", "Text", "Button")
	dflt("TextBox", "Text", "TextBox")
	dflt("ScreenGui", "IgnoreGuiInset", false)
	dflt("Sound", "SoundId", "")
	dflt("Sound", "IsPlaying", false)
	dflt("Sound", "TimeLength", 0)
	dflt("Humanoid", "Health", 100)
	dflt("Humanoid", "Sit", false)
	dflt("Humanoid", "Jump", false)
	dflt("UserInputService", "MouseBehavior", E.MouseBehavior.Default)
	dflt("UserInputService", "MouseIconEnabled", true)
	dflt("UserInputService", "TouchEnabled", false)
	dflt("UserInputService", "KeyboardEnabled", true)
	dflt("UserInputService", "MouseEnabled", true)
	dflt("UserInputService", "GamepadEnabled", false)
	dflt("UserInputService", "VREnabled", false)
	dflt("UserInputService", "ModalEnabled", false)
	dflt("Player", "CameraMode", E.CameraMode.Classic)
	dflt("Player", "CameraMinZoomDistance", 0.5)
	dflt("Player", "CameraMaxZoomDistance", 400)
	dflt("Player", "DisplayName", "Player")
	dflt("Player", "UserId", 0)
	dflt("GuiService", "MenuIsOpen", false)
	dflt("GuiService", "TouchControlsEnabled", true)
	dflt("GuiService", "AutoSelectGuiEnabled", true)
	dflt("GuiService", "GuiNavigationEnabled", true)
	dflt("Lighting", "ClockTime", 14)
	dflt("Lighting", "Brightness", 2)
	dflt("Lighting", "GlobalShadows", true)
	dflt("Lighting", "Ambient", C3.fromRGB(70, 70, 70))
	dflt("Lighting", "OutdoorAmbient", C3.fromRGB(70, 70, 70))
	dflt("Lighting", "EnvironmentDiffuseScale", 1)
	dflt("Lighting", "EnvironmentSpecularScale", 1)
	dflt("Lighting", "ExposureCompensation", 0)
	dflt("Lighting", "FogEnd", 100000)
	dflt("Lighting", "FogStart", 0)
	dflt("Lighting", "FogColor", C3.fromRGB(192, 192, 192))
	dflt("Workspace", "StreamingEnabled", false)
	dflt("Workspace", "Gravity", 196.2)
	dflt("Camera", "CameraType", E.CameraType.Custom)
	dflt("Texture", "ColorMapContent", roblox.Content.none)
	dflt("ChatWindowConfiguration", "Enabled", true)
	for _, cls in { "Part", "MeshPart", "Seat", "VehicleSeat", "WedgePart", "CornerWedgePart", "TrussPart", "SpawnLocation", "UnionOperation", "Attachment" } do
		dflt(cls, "Position", V3.zero)
		dflt(cls, "LocalTransparencyModifier", 0)
	end
	DP.Archivable = true
end

-------------------------------------------------------------------------------
-- Getters / setters

local G, S, M = Rt.Getters, Rt.Setters, Rt.Methods

local function absSizeGetter(r)
	return Layout.absSize(r)
end
G.GuiBase2d = {
	AbsoluteSize = absSizeGetter,
	AbsolutePosition = function(r)
		return Layout.absPos(r)
	end,
	AbsoluteRotation = function()
		return 0
	end,
}

local function textBoundsGetter(r)
	local w, h = Layout.textBounds(r)
	return V2.new(w, h)
end
for _, cls in { "TextLabel", "TextButton", "TextBox" } do
	G[cls] = {
		TextBounds = textBoundsGetter,
		ContentText = function(r)
			return Layout.labelText(r)
		end,
		TextFits = function(r)
			local w, h = Layout.textBounds(r)
			local L = r.layout
			if not L or not L.lw then
				return true
			end
			return w <= L.lw + 0.5 and h <= L.lh + 0.5
		end,
	}
	S[cls] = {
		Font = function(r, key, m, value, level)
			Rt.writeProp(r, key, m, value, level + 1)
			local okf, face = pcall(roblox.Font.fromEnum, r.props.Font)
			if okf and face then
				r.props.FontFace = face
				Rt.changed(r, "FontFace")
			end
		end,
	}
end

G.ScrollingFrame = {
	AbsoluteCanvasSize = function(r)
		local L = r.layout
		if not L or not L.lw then
			return V2.zero
		end
		return V2.new(L.w, math.max(L.h, (L.contentH or 0) * (L.k or 1)))
	end,
	AbsoluteWindowSize = absSizeGetter,
}

G.Camera = {
	ViewportSize = function()
		return V2.new(Layout.viewport.w, Layout.viewport.h)
	end,
}

local function rotationOf(cf: any): any
	return cf - cf.Position
end

S.BasePart = {
	CFrame = function(r, key, m, value, level)
		Rt.writeProp(r, key, m, value, level + 1)
		r.props.Position = value.Position
		Rt.changed(r, "Position")
	end,
	Position = function(r, key, m, value, level)
		Rt.writeProp(r, key, m, value, level + 1)
		local old = r.props.CFrame or CF.identity
		r.props.CFrame = CF.new(value.X, value.Y, value.Z) * rotationOf(old)
		Rt.changed(r, "CFrame")
	end,
}

local function parentPartCF(r: any): any
	local par = r.parent and recs[r.parent]
	if par and Api.isA(par.class, "BasePart") then
		return par.proxy.CFrame
	end
	return CF.identity
end
G.Attachment = {
	WorldPosition = function(r)
		local pos = r.proxy.Position
		return parentPartCF(r):PointToWorldSpace(pos)
	end,
	WorldCFrame = function(r)
		return parentPartCF(r) * r.proxy.CFrame
	end,
}
S.Attachment = {
	WorldPosition = function(r, _key, _m, value, level)
		if typeof(value) ~= "Vector3" then
			error("Unable to assign property WorldPosition. Vector3 expected, got " .. Rt.typeof(value), level + 1)
		end
		r.proxy.Position = parentPartCF(r):PointToObjectSpace(value)
	end,
	WorldCFrame = function(r, _key, _m, value, level)
		if typeof(value) ~= "CFrame" then
			error("Unable to assign property WorldCFrame. CFrame expected, got " .. Rt.typeof(value), level + 1)
		end
		r.proxy.CFrame = parentPartCF(r):Inverse() * value
	end,
}

S.Humanoid = {
	Health = function(r, key, m, value, level)
		local before = r.proxy.Health
		Rt.writeProp(r, key, m, math.clamp(tonumber(value) or 0, 0, r.proxy.MaxHealth), level + 1)
		if before > 0 and r.proxy.Health <= 0 then
			Rt.fireDeferred(Rt.getSignal(r.proxy, "Died"))
		end
	end,
	Sit = function(r, key, m, value, level)
		local before = r.proxy.Sit
		Rt.writeProp(r, key, m, value, level + 1)
		if before and not value then
			local seat = r.props.SeatPart
			Rt.setInternal(r.proxy, "SeatPart", nil)
			if seat and seat ~= Rt.NIL and recs[seat] then
				Rt.setInternal(seat, "Occupant", nil)
			end
			Rt.fireDeferred(Rt.getSignal(r.proxy, "Seated"), false, nil)
		end
	end,
}

-------------------------------------------------------------------------------
-- Generic engine methods

M.PVInstance = {
	GetPivot = function(self)
		local r = selfRec(self, "GetPivot")
		if Api.isA(r.class, "BasePart") then
			return self.CFrame
		end
		local pp = r.props.PrimaryPart
		if pp and pp ~= Rt.NIL then
			return pp.CFrame
		end
		local first = Rt.findFirst(r, function(c)
			return Api.isA(c.class, "BasePart")
		end, true)
		if first then
			return first.CFrame
		end
		return CF.identity
	end,
	PivotTo = function(self, cf)
		local r = selfRec(self, "PivotTo")
		if typeof(cf) ~= "CFrame" then
			error("invalid argument #1 to 'PivotTo' (CFrame expected, got " .. Rt.typeof(cf) .. ")", 2)
		end
		if Api.isA(r.class, "BasePart") then
			self.CFrame = cf
			return
		end
		local delta = cf * self:GetPivot():Inverse()
		Rt.eachDescendant(r, function(d)
			if Api.isA(d.class, "BasePart") then
				d.proxy.CFrame = delta * d.proxy.CFrame
			end
		end)
	end,
}
M.Model = {
	GetBoundingBox = function(self)
		return self:GetPivot(), V3.new(4, 5, 2)
	end,
	GetExtentsSize = function()
		return V3.new(4, 5, 2)
	end,
	MoveTo = function(self, pos)
		self:PivotTo(CF.new(pos.X, pos.Y, pos.Z))
	end,
}
M.BasePart = {
	GetMass = function()
		return 1
	end,
	GetTouchingParts = function()
		return {}
	end,
	GetConnectedParts = function()
		return {}
	end,
}

M.GuiObject = {
	TweenSize = function(self, size)
		self.Size = size
		return true
	end,
	TweenPosition = function(self, pos)
		self.Position = pos
		return true
	end,
	TweenSizeAndPosition = function(self, size, pos)
		self.Size = size
		self.Position = pos
		return true
	end,
}
M.TextBox = {
	CaptureFocus = function() end,
	ReleaseFocus = function() end,
	IsFocused = function()
		return false
	end,
}

-- DataModel ---------------------------------------------------------------------

M.ServiceProvider = {
	GetService = function(self, name)
		selfRec(self, "GetService")
		if type(name) ~= "string" then
			error("invalid argument #1 to 'GetService' (string expected)", 2)
		end
		local s = World.services[name]
		if s then
			return s
		end
		if Api.isService(name) then
			return World.addService(name)
		end
		error(string.format("'%s' is not a valid Service name", name), 2)
	end,
	FindService = function(self, name)
		return World.services[name]
	end,
}
M.DataModel = {
	IsLoaded = function()
		return true
	end,
	BindToClose = function() end,
	GetJobsInfo = function()
		return {}
	end,
}

M.Workspace = {
	GetServerTimeNow = function()
		return 1760000000 + Sched.now
	end,
	Raycast = function(self, origin, direction, params)
		World.raycasts += 1
		if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
			error("invalid argument to 'Raycast' (Vector3 expected)", 2)
		end
		if params ~= nil and Rt.typeof(params) ~= "RaycastParams" then
			error("invalid argument #3 to 'Raycast' (RaycastParams expected, got " .. Rt.typeof(params) .. ")", 2)
		end
		if params ~= nil then
			for _, x in params.FilterDescendantsInstances do
				if x ~= nil and not Rt.isInstance(x) then
					error("RaycastParams.FilterDescendantsInstances must only contain Instances", 2)
				end
			end
		end
		-- no physics: a floor hit at y = 0 if the ray goes down, else nothing
		if direction.Y < -1e-6 and origin.Y > 0 then
			local t = -origin.Y / direction.Y
			if t <= 1 then
				local pos = origin + direction * t
				return Rt.record("RaycastResult", { Position = pos, Normal = V3.new(0, 1, 0), Distance = (direction * t).Magnitude, Instance = World.floor, Material = E.Material.Plastic })
			end
		end
		return nil
	end,
	Blockcast = function()
		return nil
	end,
	Spherecast = function()
		return nil
	end,
	Shapecast = function()
		return nil
	end,
	GetPartBoundsInBox = function()
		return {}
	end,
	GetPartBoundsInRadius = function()
		return {}
	end,
	GetPartsInPart = function()
		return {}
	end,
}

-- Camera projection (pinhole, vertical FieldOfView)
local function project(cam: any, pos: any): (any, boolean)
	local cf = cam.CFrame
	local fov = math.rad(cam.FieldOfView)
	local W, H = Layout.viewport.w, Layout.viewport.h
	local p = cf:PointToObjectSpace(pos)
	local depth = -p.Z
	local t = math.tan(fov / 2)
	if math.abs(depth) < 1e-6 then
		depth = -1e-6
	end
	local nx = p.X / (depth * t * (W / H))
	local ny = p.Y / (depth * t)
	local sx = (nx + 1) / 2 * W
	local sy = (1 - ny) / 2 * H
	local on = depth > 0 and sx >= 0 and sx <= W and sy >= 0 and sy <= H
	return V3.new(sx, sy, depth), on
end
World.project = project

local function viewportRay(cam: any, x: number, y: number, depth: number?): any
	local cf = cam.CFrame
	local fov = math.rad(cam.FieldOfView)
	local W, H = Layout.viewport.w, Layout.viewport.h
	local t = math.tan(fov / 2)
	local nx, ny = x / W * 2 - 1, 1 - y / H * 2
	local dir = cf:VectorToWorldSpace(V3.new(nx * t * (W / H), ny * t, -1).Unit)
	return roblox.Ray.new(cf.Position + dir * (depth or 0), dir)
end

M.Camera = {
	WorldToViewportPoint = function(self, pos)
		if typeof(pos) ~= "Vector3" then
			error("invalid argument #1 to 'WorldToViewportPoint' (Vector3 expected, got " .. Rt.typeof(pos) .. ")", 2)
		end
		return project(self, pos)
	end,
	WorldToScreenPoint = function(self, pos)
		local v, on = project(self, pos)
		return V3.new(v.X, v.Y - Layout.TOP_INSET, v.Z), on
	end,
	ViewportPointToRay = function(self, x, y, depth)
		return viewportRay(self, x, y, depth)
	end,
	ScreenPointToRay = function(self, x, y, depth)
		return viewportRay(self, x, y + Layout.TOP_INSET, depth)
	end,
	GetRenderCFrame = function(self)
		return self.CFrame
	end,
	ZoomToExtents = function() end,
}

-- Players ----------------------------------------------------------------------

M.Players = {
	GetPlayers = function(self)
		local r = selfRec(self, "GetPlayers")
		local out = {}
		for _, c in r.children do
			if recs[c].class == "Player" then
				table.insert(out, c)
			end
		end
		return out
	end,
	GetPlayerFromCharacter = function(self, character)
		for _, p in self:GetPlayers() do
			if p.Character == character and character ~= nil then
				return p
			end
		end
		return nil
	end,
	GetPlayerByUserId = function(self, id)
		for _, p in self:GetPlayers() do
			if p.UserId == id then
				return p
			end
		end
		return nil
	end,
}
M.Player = {
	GetMouse = function(self)
		local r = selfRec(self, "GetMouse")
		if not r.mouse then
			r.mouse = Rt.newInstance("PlayerMouse")
		end
		return r.mouse
	end,
	Kick = function(_, msg)
		Rt.note("Player:Kick called: " .. tostring(msg))
	end,
	GetNetworkPing = function()
		return 0.05
	end,
	IsInGroup = function()
		return false
	end,
	GetRankInGroup = function()
		return 0
	end,
	LoadCharacter = function()
		World.respawn()
	end,
}

-- Input --------------------------------------------------------------------------

M.UserInputService = {
	GetMouseLocation = function()
		local uis = service("UserInputService")
		if uis.MouseBehavior == E.MouseBehavior.LockCenter then
			return V2.new(Layout.viewport.w / 2, Layout.viewport.h / 2)
		end
		return World.mouse
	end,
	GetMouseDelta = function()
		return V2.zero
	end,
	GetLastInputType = function()
		return World.lastInputType or E.UserInputType.Keyboard
	end,
	IsKeyDown = function()
		return false
	end,
	IsMouseButtonPressed = function()
		return false
	end,
	GetKeysPressed = function()
		return {}
	end,
	GetMouseButtonsPressed = function()
		return {}
	end,
	GetFocusedTextBox = function()
		return nil
	end,
	GetConnectedGamepads = function()
		return if service("UserInputService").GamepadEnabled then { E.UserInputType.Gamepad1 } else {}
	end,
	GetGamepadConnected = function(_, gp)
		return service("UserInputService").GamepadEnabled and gp == E.UserInputType.Gamepad1
	end,
	GetNavigationGamepads = function()
		return {}
	end,
	GetStringForKeyCode = function(_, kc)
		return kc.Name
	end,
	GetImageForKeyCode = function()
		return ""
	end,
	GetDeviceType = function()
		return nil
	end,
}

M.RunService = {
	IsClient = function()
		return true
	end,
	IsServer = function()
		return false
	end,
	IsStudio = function()
		return World.opts.studio
	end,
	IsRunning = function()
		return true
	end,
	IsRunMode = function()
		return false
	end,
	IsEdit = function()
		return false
	end,
	BindToRenderStep = function(_, name, priority, fn)
		if type(name) ~= "string" or type(priority) ~= "number" or type(fn) ~= "function" then
			error("invalid arguments to BindToRenderStep (string, number, function expected)", 2)
		end
		table.insert(World.renderBindings, { name = name, priority = priority, fn = fn })
	end,
	UnbindFromRenderStep = function(_, name)
		for i = #World.renderBindings, 1, -1 do
			if World.renderBindings[i].name == name then
				table.remove(World.renderBindings, i)
			end
		end
	end,
	Set3dRenderingEnabled = function() end,
}

M.GuiService = {
	GetGuiInset = function()
		return V2.new(0, Layout.TOP_INSET), V2.zero
	end,
	IsTenFootInterface = function()
		return false
	end,
	Select = function() end,
	AddSelectionParent = function() end,
	RemoveSelectionGroup = function() end,
	CloseInspectMenu = function() end,
	GetEmotesMenuOpen = function()
		return false
	end,
	SetEmotesMenuOpen = function() end,
}

M.ContextActionService = {
	BindAction = function(_, name, fn, touch, ...)
		if type(name) ~= "string" or type(fn) ~= "function" then
			error("invalid arguments to BindAction (string, function expected)", 2)
		end
		World.cas[name] = { name = name, fn = fn, touch = touch, priority = 2000, inputs = { ... }, seq = Sched.frame }
	end,
	BindActionAtPriority = function(_, name, fn, touch, priority, ...)
		if type(name) ~= "string" or type(fn) ~= "function" or type(priority) ~= "number" then
			error("invalid arguments to BindActionAtPriority (string, function, bool, number expected)", 2)
		end
		World.cas[name] = { name = name, fn = fn, touch = touch, priority = priority, inputs = { ... }, seq = Sched.frame }
	end,
	UnbindAction = function(_, name)
		World.cas[name] = nil
	end,
	UnbindAllActions = function()
		table.clear(World.cas)
	end,
	SetTitle = function(_, name, title)
		if World.cas[name] then
			World.cas[name].title = title
		end
	end,
	SetImage = function(_, name, img)
		if World.cas[name] then
			World.cas[name].image = img
		end
	end,
	SetDescription = function() end,
	SetPosition = function(_, name, pos)
		if World.cas[name] then
			if typeof(pos) ~= "UDim2" then
				error("invalid argument #2 to 'SetPosition' (UDim2 expected, got " .. Rt.typeof(pos) .. ")", 2)
			end
			World.cas[name].position = pos
		end
	end,
	GetButton = function()
		return nil
	end,
	GetBoundActionInfo = function(_, name)
		local b = World.cas[name]
		return if b then { priorityLevel = b.priority, title = b.title, createTouchButton = b.touch, inputTypes = b.inputs } else {}
	end,
	GetAllBoundActionInfo = function()
		local out = {}
		for n, b in World.cas do
			out[n] = { priorityLevel = b.priority }
		end
		return out
	end,
}

-- Tweens -----------------------------------------------------------------------------

local TWEENABLE = { number = true, boolean = true, CFrame = true, Rect = true, Color3 = true, UDim = true, UDim2 = true, Vector2 = true, Vector2int16 = true, Vector3 = true }

World.tweens = { created = 0, played = 0 }

M.TweenService = {
	Create = function(_, inst, info, goals)
		local ir = recs[inst]
		if not ir then
			error("invalid argument #1 to 'Create' (Instance expected, got " .. Rt.typeof(inst) .. ")", 2)
		end
		if Rt.typeof(info) ~= "TweenInfo" then
			error("invalid argument #2 to 'Create' (TweenInfo expected, got " .. Rt.typeof(info) .. ")", 2)
		end
		if type(goals) ~= "table" then
			error("invalid argument #3 to 'Create' (table expected, got " .. Rt.typeof(goals) .. ")", 2)
		end
		for k, v in goals do
			local m = ir.impl.members[k]
			if not m or m.kind ~= "p" then
				error(string.format("TweenService:Create no property named '%s' for object '%s'", tostring(k), ir.name), 2)
			end
			local cur = inst[k]
			local vt, ct = Rt.typeof(v), Rt.typeof(cur)
			if not TWEENABLE[vt] or vt ~= ct then
				error(string.format("TweenService:Create property named '%s' cannot be tweened due to type mismatch (property is a '%s', but given type is '%s')", k, ct, vt), 2)
			end
		end
		World.tweens.created += 1
		local t = Rt.newInstance("Tween")
		local tr = recs[t]
		tr.tween = { inst = inst, info = info, goals = table.clone(goals), token = 0 }
		Rt.setInternal(t, "PlaybackState", E.PlaybackState.Begin)
		return t
	end,
	GetValue = function(_, alpha)
		return alpha
	end,
}
M.Tween = {
	Play = function(self)
		local r = selfRec(self, "Play")
		local tw = r.tween
		if not tw then
			return
		end
		World.tweens.played += 1
		tw.token += 1
		local my = tw.token
		local ir = recs[tw.inst]
		if ir.destroyed then
			return
		end
		for k, v in tw.goals do
			tw.inst[k] = v -- end value applied at once (documented approximation)
		end
		Rt.setInternal(self, "PlaybackState", E.PlaybackState.Playing)
		local info = tw.info
		if info.RepeatCount < 0 then
			return
		end
		local total = (info.Time + info.DelayTime) * (info.RepeatCount + 1) * (if info.Reverses then 2 else 1)
		Sched.delay(total, function()
			if tw.token == my and not r.destroyed then
				Rt.setInternal(self, "PlaybackState", E.PlaybackState.Completed)
				Rt.fire(Rt.getSignal(self, "Completed"), E.PlaybackState.Completed)
			end
		end)
	end,
	Cancel = function(self)
		local r = selfRec(self, "Cancel")
		if r.tween then
			r.tween.token += 1
		end
		Rt.setInternal(self, "PlaybackState", E.PlaybackState.Cancelled)
		Rt.fire(Rt.getSignal(self, "Completed"), E.PlaybackState.Cancelled)
	end,
	Pause = function(self)
		local r = selfRec(self, "Pause")
		if r.tween then
			r.tween.token += 1
		end
		Rt.setInternal(self, "PlaybackState", E.PlaybackState.Paused)
	end,
}

-- Sound -------------------------------------------------------------------------------

World.sounds = { played = 0 }
M.Sound = {
	Play = function(self)
		local r = selfRec(self, "Play")
		World.sounds.played += 1
		Rt.setInternal(self, "IsPlaying", true)
		Rt.fireDeferred(Rt.getSignal(self, "Played"), self.SoundId)
		if self.SoundId ~= "" and not self.Looped then
			r.playToken = (r.playToken or 0) + 1
			local my = r.playToken
			Sched.delay(1.5, function()
				if r.playToken == my and not r.destroyed then
					Rt.setInternal(self, "IsPlaying", false)
					Rt.fire(Rt.getSignal(self, "Ended"), self.SoundId)
				end
			end)
		end
	end,
	Stop = function(self)
		local r = selfRec(self, "Stop")
		r.playToken = (r.playToken or 0) + 1
		Rt.setInternal(self, "IsPlaying", false)
		Rt.fireDeferred(Rt.getSignal(self, "Stopped"), self.SoundId)
	end,
	Pause = function(self)
		local r = selfRec(self, "Pause")
		r.playToken = (r.playToken or 0) + 1
		Rt.setInternal(self, "IsPlaying", false)
	end,
	Resume = function(self)
		self:Play()
	end,
}
M.SoundService = {
	PlayLocalSound = function() end,
	GetListener = function()
		return E.ListenerType.Camera, nil
	end,
	SetListener = function() end,
}

-- Remotes -------------------------------------------------------------------------------

-- Values that survive a Roblox remote boundary: deep copy tables, flag the
-- ones Roblox would refuse or silently mangle.
function World.remoteCopy(v: any, issues: { string }, path: string, depth: number?): any
	local d = depth or 0
	local t = Rt.typeof(v)
	if t == "table" then
		if d > 40 then
			table.insert(issues, path .. ": table nesting too deep (cyclic?)")
			return nil
		end
		if getmetatable(v) ~= nil then
			table.insert(issues, path .. ": metatable is dropped across the network")
		end
		local out = {}
		local hasArray, hasHash = false, false
		local n = #v
		for k, x in v do
			if type(k) == "number" and k >= 1 and k <= n and k % 1 == 0 then
				hasArray = true
			else
				hasHash = true
				if type(k) ~= "string" then
					table.insert(issues, path .. ": non-string dictionary key " .. tostring(k) .. " (" .. Rt.typeof(k) .. ")")
				end
			end
			out[k] = World.remoteCopy(x, issues, path .. "." .. tostring(k), d + 1)
		end
		if hasArray and hasHash then
			table.insert(issues, path .. ": mixed array/dictionary table (Roblox drops one part)")
		end
		return out
	elseif t == "function" or t == "thread" or t == "userdata" then
		table.insert(issues, path .. ": " .. t .. " cannot be sent through a remote")
		return nil
	elseif t == "Instance" then
		return v
	end
	return v
end

M.RemoteEvent = {
	FireServer = function(self, ...)
		local r = selfRec(self, "FireServer")
		local issues = {}
		local args = table.pack(...)
		local copy = { n = args.n }
		for i = 1, args.n do
			copy[i] = World.remoteCopy(args[i], issues, "arg" .. i)
		end
		local entry = { remote = r.name, args = copy, t = Sched.now, site = Rt.callSite(), issues = issues, scenario = World.scenario }
		table.insert(World.remoteLog, entry)
		local h = World.serverHandlers[r.name]
		if h then
			Sched.defer(function()
				h(table.unpack(copy, 1, copy.n))
			end)
		end
	end,
	FireClient = function()
		error("FireClient can only be called from the server", 2)
	end,
	FireAllClients = function()
		error("FireAllClients can only be called from the server", 2)
	end,
}
M.UnreliableRemoteEvent = M.RemoteEvent
M.RemoteFunction = {
	InvokeServer = function(self, ...)
		local r = selfRec(self, "InvokeServer")
		table.insert(World.remoteLog, { remote = r.name, args = table.pack(...), t = Sched.now, site = Rt.callSite(), issues = {}, scenario = World.scenario })
		local h = World.serverHandlers[r.name]
		if h then
			return h(...)
		end
		return nil
	end,
}
M.BindableEvent = {
	Fire = function(self, ...)
		Rt.fireDeferred(Rt.getSignal(self, "Event"), ...)
	end,
}
M.BindableFunction = {
	Invoke = function(self, ...)
		local r = selfRec(self, "Invoke")
		local cb = r.callbacks and r.callbacks.OnInvoke
		if not cb then
			error("BindableFunction has no OnInvoke callback", 2)
		end
		return cb(...)
	end,
}

-- Proximity prompts -------------------------------------------------------------------

M.ProximityPrompt = {
	InputHoldBegin = function(self)
		local r = selfRec(self, "InputHoldBegin")
		local pps = service("ProximityPromptService")
		local player = World.player
		r.holding = true
		r.holdToken = (r.holdToken or 0) + 1
		r.triggered = false
		local my = r.holdToken
		local function trigger()
			r.triggered = true
			Rt.fire(Rt.getSignal(self, "Triggered"), player)
			Rt.fire(Rt.getSignal(pps, "PromptTriggered"), self, player)
		end
		if self.HoldDuration <= 0 then
			trigger()
		else
			Rt.fire(Rt.getSignal(self, "PromptButtonHoldBegan"), player)
			Rt.fire(Rt.getSignal(pps, "PromptButtonHoldBegan"), self, player)
			Sched.delay(self.HoldDuration, function()
				if r.holding and r.holdToken == my then
					trigger()
				end
			end)
		end
	end,
	InputHoldEnd = function(self)
		local r = selfRec(self, "InputHoldEnd")
		local pps = service("ProximityPromptService")
		if not r.holding then
			return
		end
		r.holding = false
		if self.HoldDuration > 0 then
			Rt.fire(Rt.getSignal(self, "PromptButtonHoldEnded"), World.player)
			Rt.fire(Rt.getSignal(pps, "PromptButtonHoldEnded"), self, World.player)
		end
		if r.triggered then
			Rt.fire(Rt.getSignal(self, "TriggerEnded"), World.player)
			Rt.fire(Rt.getSignal(pps, "PromptTriggerEnded"), self, World.player)
		end
	end,
}

-- Humanoid / Seat ------------------------------------------------------------------------

M.Humanoid = {
	TakeDamage = function(self, n)
		self.Health = self.Health - n
	end,
	ChangeState = function(self, state)
		local r = selfRec(self, "ChangeState")
		r.state = state
		Rt.fireDeferred(Rt.getSignal(self, "StateChanged"), E.HumanoidStateType.Running, state)
	end,
	GetState = function(self)
		local r = selfRec(self, "GetState")
		return r.state or E.HumanoidStateType.Running
	end,
	SetStateEnabled = function() end,
	GetStateEnabled = function()
		return true
	end,
	MoveTo = function() end,
	Move = function() end,
	UnequipTools = function() end,
	EquipTool = function() end,
	GetPlayingAnimationTracks = function()
		return {}
	end,
	GetAppliedDescription = function()
		return Rt.newInstance("HumanoidDescription")
	end,
}
M.Seat = {
	Sit = function(self, humanoid)
		World.seat(humanoid, self)
	end,
}
M.VehicleSeat = M.Seat

-- Collections ---------------------------------------------------------------------------

local tagAdded: { [string]: any } = {}
local tagRemoved: { [string]: any } = {}
local function tagSignal(map: any, tag: string): any
	local s = map[tag]
	if not s then
		s = Rt.newSignal("CollectionService(" .. tag .. ")")
		map[tag] = s
	end
	return s
end
Rt.onTagAdded = function(r, tag)
	if Rt.inDataModel(r) and tagAdded[tag] then
		Rt.fireDeferred(tagAdded[tag], r.proxy)
	end
end
Rt.onTagRemoved = function(r, tag)
	if Rt.inDataModel(r) and tagRemoved[tag] then
		Rt.fireDeferred(tagRemoved[tag], r.proxy)
	end
end
Rt.onTaggedEnter = function(r)
	for tag in r.tags do
		if tagAdded[tag] then
			Rt.fireDeferred(tagAdded[tag], r.proxy)
		end
	end
end
Rt.onTaggedLeave = function(r)
	for tag in r.tags do
		if tagRemoved[tag] then
			Rt.fireDeferred(tagRemoved[tag], r.proxy)
		end
	end
end
M.CollectionService = {
	GetTagged = function(_, tag)
		local out = {}
		Rt.eachDescendant(recs[World.game], function(d)
			if d.tags[tag] then
				table.insert(out, d.proxy)
			end
		end)
		return out
	end,
	GetInstanceAddedSignal = function(_, tag)
		return tagSignal(tagAdded, tag)
	end,
	GetInstanceRemovedSignal = function(_, tag)
		return tagSignal(tagRemoved, tag)
	end,
	AddTag = function(_, inst, tag)
		inst:AddTag(tag)
	end,
	RemoveTag = function(_, inst, tag)
		inst:RemoveTag(tag)
	end,
	HasTag = function(_, inst, tag)
		return inst:HasTag(tag)
	end,
	GetTags = function(_, inst)
		return inst:GetTags()
	end,
	GetAllTags = function()
		local set, out = {}, {}
		Rt.eachDescendant(recs[World.game], function(d)
			for t in d.tags do
				if not set[t] then
					set[t] = true
					table.insert(out, t)
				end
			end
		end)
		return out
	end,
}

-- Assets ----------------------------------------------------------------------------------

World.editableStats = { images = 0, meshes = 0, meshParts = 0, vertices = 0, triangles = 0 }
local function editablesGuard(kind: string)
	if not World.opts.editables then
		error(kind .. " is unavailable (smoke harness running with --no-editables)", 3)
	end
end
M.AssetService = {
	CreateEditableImage = function(_, opts)
		editablesGuard("EditableImage")
		local size = (type(opts) == "table" and opts.Size) or V2.new(512, 512)
		if typeof(size) ~= "Vector2" or size.X < 1 or size.Y < 1 or size.X > 1024 or size.Y > 1024 then
			error("CreateEditableImage: Size must be a Vector2 between 1 and 1024", 2)
		end
		local img = Rt.newInstance("EditableImage")
		Rt.setInternal(img, "Size", size)
		World.editableStats.images += 1
		return img
	end,
	CreateEditableMesh = function()
		editablesGuard("EditableMesh")
		World.editableStats.meshes += 1
		local m = Rt.newInstance("EditableMesh")
		recs[m].mesh = { v = 0, n = 0, uv = 0, c = 0, f = 0 }
		return m
	end,
	CreateEditableImageAsync = function(self, _content, opts)
		return M.AssetService.CreateEditableImage(self, opts)
	end,
	CreateEditableMeshAsync = function(self)
		return M.AssetService.CreateEditableMesh(self)
	end,
	CreateMeshPartAsync = function(_, content)
		editablesGuard("MeshPart from EditableMesh")
		if typeof(content) ~= "Content" then
			error("invalid argument #1 to 'CreateMeshPartAsync' (Content expected, got " .. Rt.typeof(content) .. ")", 2)
		end
		World.editableStats.meshParts += 1
		return Rt.newInstance("MeshPart")
	end,
}
M.EditableImage = {
	WritePixelsBuffer = function(self, pos, size, buf)
		selfRec(self, "WritePixelsBuffer")
		if typeof(pos) ~= "Vector2" or typeof(size) ~= "Vector2" then
			error("WritePixelsBuffer: position and size must be Vector2", 2)
		end
		if type(buf) ~= "buffer" then
			error("WritePixelsBuffer: buffer expected, got " .. Rt.typeof(buf), 2)
		end
		if buffer.len(buf) ~= size.X * size.Y * 4 then
			error(string.format("WritePixelsBuffer: buffer length %d does not match size %dx%dx4", buffer.len(buf), size.X, size.Y), 2)
		end
		local img = self.Size
		if pos.X < 0 or pos.Y < 0 or pos.X + size.X > img.X or pos.Y + size.Y > img.Y then
			error("WritePixelsBuffer: region is outside the image", 2)
		end
	end,
	ReadPixelsBuffer = function(_, _pos, size)
		return buffer.create(size.X * size.Y * 4)
	end,
	DrawRectangle = function() end,
	DrawCircle = function() end,
	DrawLine = function() end,
	DrawImage = function() end,
}
local function meshAdd(field: string, limit: number?)
	return function(self)
		local r = selfRec(self, "EditableMesh")
		local m = r.mesh
		m[field] += 1
		if field == "v" then
			World.editableStats.vertices += 1
			if m.v > 60000 then
				error("EditableMesh vertex limit (60000) exceeded", 2)
			end
		end
		return m[field]
	end
end
M.EditableMesh = {
	AddVertex = meshAdd("v"),
	AddNormal = meshAdd("n"),
	AddUV = meshAdd("uv"),
	AddColor = meshAdd("c"),
	AddTriangle = function(self, a, b, c)
		local r = selfRec(self, "AddTriangle")
		local m = r.mesh
		for _, id in { a, b, c } do
			if type(id) ~= "number" or id < 1 or id > m.v then
				error("AddTriangle: invalid vertex id " .. tostring(id), 2)
			end
		end
		if m.f >= 20000 then
			error("EditableMesh triangle limit (20000) exceeded", 2)
		end
		m.f += 1
		World.editableStats.triangles += 1
		return m.f
	end,
	SetFaceNormals = function(_, fid, ids)
		if type(ids) ~= "table" or #ids ~= 3 then
			error("SetFaceNormals expects 3 ids", 2)
		end
	end,
	SetFaceUVs = function(_, fid, ids)
		if type(ids) ~= "table" or #ids ~= 3 then
			error("SetFaceUVs expects 3 ids", 2)
		end
	end,
	SetFaceColors = function(_, fid, ids)
		if type(ids) ~= "table" or #ids ~= 3 then
			error("SetFaceColors expects 3 ids", 2)
		end
	end,
	GetVertices = function(self)
		local out = {}
		for i = 1, recs[self].mesh.v do
			out[i] = i
		end
		return out
	end,
	GetFaces = function(self)
		local out = {}
		for i = 1, recs[self].mesh.f do
			out[i] = i
		end
		return out
	end,
}

-- Misc services -------------------------------------------------------------------------------

M.TextService = {
	GetTextSize = function(_, text, size, font, frame)
		local _, _, wf = 0, 0, 0.55
		local w, h = Layout.measure(tostring(text), size, wf, if frame and frame.X > 0 and frame.X < 1e5 then frame.X else nil)
		return V2.new(w, h)
	end,
	GetTextBoundsAsync = function(_, params)
		local w, h = Layout.measure(params.Text, params.Size, 0.55, if params.Width > 0 then params.Width else nil)
		return V2.new(w, h)
	end,
}
M.HttpService = {
	JSONEncode = function(_, v)
		return serde.encode("json", v)
	end,
	JSONDecode = function(_, s)
		return serde.decode("json", s)
	end,
	GenerateGUID = function(_, braces)
		local s = string.format("%08X-%04X-%04X-%04X-%012X", math.random(0, 0x7FFFFFFF), math.random(0, 0xFFFF), math.random(0, 0xFFFF), math.random(0, 0xFFFF), math.random(0, 0x7FFFFFFF))
		return if braces == false then s else "{" .. s .. "}"
	end,
}
M.Debris = {
	AddItem = function(_, inst, t)
		Sched.delay(t or 10, function()
			local r = recs[inst]
			if r and not r.destroyed then
				Rt.destroy(r)
			end
		end)
	end,
}
M.StarterGui = {
	SetCore = function(_, name, value)
		table.insert(World.coreCalls, { "SetCore", name, value })
	end,
	GetCore = function(_, name)
		return nil
	end,
	SetCoreGuiEnabled = function(_, kind, enabled)
		table.insert(World.coreCalls, { "SetCoreGuiEnabled", tostring(kind), enabled })
	end,
	GetCoreGuiEnabled = function()
		return true
	end,
}
M.Lighting = {
	GetMinutesAfterMidnight = function(self)
		return self.ClockTime * 60
	end,
	SetMinutesAfterMidnight = function(self, m)
		self.ClockTime = m / 60
	end,
	GetSunDirection = function()
		return V3.new(0, 1, 0)
	end,
	GetMoonDirection = function()
		return V3.new(0, 1, 0)
	end,
}
M.PlayerGui = {
	GetTopbarTransparency = function()
		return 0
	end,
	SetTopbarTransparency = function() end,
}

-------------------------------------------------------------------------------
-- World construction

local luneGame = roblox.Instance.new("DataModel")

function World.addService(name: string): any
	local ok, shadow = pcall(function()
		return luneGame:GetService(name)
	end)
	local s = Rt.newInstance(name, { shadow = if ok then shadow else false, name = name })
	if not recs[s].shadow then
		recs[s].shadow = nil
	end
	World.services[name] = s
	Rt.setParent(recs[s], World.game, 1)
	return s
end

function World.build(): any
	World.registerDefaults()
	Rt.resetImpls()
	World.services = {}
	local game = Rt.newInstance("DataModel", { shadow = false, name = "Game" })
	recs[game].shadow = nil
	World.game = game
	Rt.dataModel = game
	for _, name in {
		"Workspace", "Players", "Lighting", "ReplicatedStorage", "ReplicatedFirst", "ServerScriptService", "ServerStorage",
		"StarterGui", "StarterPack", "StarterPlayer", "SoundService", "TextChatService", "RunService", "UserInputService",
		"TweenService", "ContextActionService", "GuiService", "ProximityPromptService", "CollectionService", "AssetService",
		"HttpService", "TextService", "Debris", "Teams", "Chat",
	} do
		World.addService(name)
	end
	local ws = World.services.Workspace
	World.workspace = ws
	local cam = Rt.newInstance("Camera", { name = "Camera" })
	cam.Parent = ws
	Rt.setInternal(ws, "CurrentCamera", cam)
	cam.CameraType = E.CameraType.Custom
	cam.FieldOfView = 70
	cam.CFrame = CF.new(12, 4.5, 9)
	World.camera = cam
	local floor = Rt.newInstance("Part", { name = "Floor" })
	floor.Anchored = true
	floor.Size = V3.new(200, 1, 200)
	floor.CFrame = CF.new(0, -0.5, 0)
	World.floor = floor

	-- StarterPlayer settings from default.project.json
	local sp = World.services.StarterPlayer
	local sps = Rt.newInstance("StarterPlayerScripts", { name = "StarterPlayerScripts" })
	sps.Parent = sp
	local scs = Rt.newInstance("StarterCharacterScripts", { name = "StarterCharacterScripts" })
	scs.Parent = sp

	local chatWin = Rt.newInstance("ChatWindowConfiguration", { name = "ChatWindowConfiguration" })
	chatWin.Parent = World.services.TextChatService

	-- local player
	local players = World.services.Players
	local player = Rt.newInstance("Player", { name = "SmokeTester" })
	Rt.setInternal(player, "UserId", 1001)
	Rt.setInternal(player, "DisplayName", "Smoke")
	player.CameraMode = E.CameraMode.LockFirstPerson
	player.CameraMinZoomDistance = 0.5
	player.CameraMaxZoomDistance = 0.5
	local pg = Rt.newInstance("PlayerGui", { name = "PlayerGui" })
	pg.Parent = player
	local ps = Rt.newInstance("PlayerScripts", { name = "PlayerScripts" })
	ps.Parent = player
	local bp = Rt.newInstance("Backpack", { name = "Backpack" })
	bp.Parent = player
	player.Parent = players
	Rt.setInternal(players, "LocalPlayer", player)
	World.player = player
	World.playerGui = pg
	return game
end

function World.addTeammate(name: string, userId: number, attrs: { [string]: any }?): any
	local p = Rt.newInstance("Player", { name = name })
	Rt.setInternal(p, "UserId", userId)
	Rt.setInternal(p, "DisplayName", name)
	for k, v in attrs or {} do
		p:SetAttribute(k, v)
	end
	p.Parent = World.services.Players
	Rt.fireDeferred(Rt.getSignal(World.services.Players, "PlayerAdded"), p)
	return p
end

World.spawnCF = CF.new(12, 3, 9)

function World.spawnCharacter(): any
	local player = World.player
	local model = Rt.newInstance("Model", { name = player.Name })
	local hum = Rt.newInstance("Humanoid", { name = "Humanoid" })
	hum.Parent = model
	local root = Rt.newInstance("Part", { name = "HumanoidRootPart" })
	root.Size = V3.new(2, 2, 1)
	root.CFrame = World.spawnCF
	root.Transparency = 1
	root.Parent = model
	local head = Rt.newInstance("Part", { name = "Head" })
	head.Size = V3.new(2, 1, 1)
	head.CFrame = World.spawnCF * CF.new(0, 1.5, 0)
	head.Parent = model
	local animator = Rt.newInstance("Animator", { name = "Animator" })
	animator.Parent = hum
	model.PrimaryPart = root
	model.Parent = World.workspace
	player.Character = model
	World.character = model
	World.humanoid = hum
	-- the default camera scripts point the camera at the new humanoid
	World.camera.CameraSubject = hum
	World.camera.CameraType = E.CameraType.Custom
	Rt.fire(Rt.getSignal(player, "CharacterAdded"), model)
	Rt.fireDeferred(Rt.getSignal(player, "CharacterAppearanceLoaded"), model)
	return model
end

function World.kill()
	local hum = World.humanoid
	if hum and recs[hum] and not recs[hum].destroyed then
		hum.Health = 0
	end
end

function World.respawn()
	local player = World.player
	local old = World.character
	if old and not recs[old].destroyed then
		Rt.fire(Rt.getSignal(player, "CharacterRemoving"), old)
		Sched.flushDeferred()
		old:Destroy()
	end
	return World.spawnCharacter()
end

-- emulates the server seating the humanoid in a Seat
function World.seat(hum: any, seatPart: any)
	Rt.setInternal(seatPart, "Occupant", hum)
	Rt.setInternal(hum, "SeatPart", seatPart)
	Rt.setInternal(hum, "Sit", true)
	Rt.fire(Rt.getSignal(hum, "Seated"), true, seatPart)
end

-- the engine standing a seated humanoid up (jump / server weld removal)
function World.unseat(hum: any)
	local seat = hum.SeatPart
	if seat then
		Rt.setInternal(seat, "Occupant", nil)
	end
	Rt.setInternal(hum, "SeatPart", nil)
	if hum.Sit then
		Rt.setInternal(hum, "Sit", false)
		Rt.fire(Rt.getSignal(hum, "Seated"), false, nil)
	end
end

function World.setViewport(w: number, h: number)
	Layout.viewport.w = w
	Layout.viewport.h = h
	World.mouse = V2.new(w / 2, h / 2)
	Rt.changed(recs[World.camera], "ViewportSize")
	Layout.forceAll = true
	Rt.layoutDirty = true
end

function World.setInputType(kind: string)
	local uis = World.services.UserInputService
	local map = {
		keyboard = E.UserInputType.Keyboard,
		mouse = E.UserInputType.MouseMovement,
		gamepad = E.UserInputType.Gamepad1,
		touch = E.UserInputType.Touch,
	}
	local t = map[kind]
	Rt.setInternal(uis, "TouchEnabled", kind == "touch")
	Rt.setInternal(uis, "GamepadEnabled", kind == "gamepad")
	Rt.setInternal(uis, "MouseEnabled", kind ~= "touch")
	Rt.setInternal(uis, "KeyboardEnabled", kind ~= "touch")
	World.lastInputType = t
	Rt.fire(Rt.getSignal(uis, "LastInputTypeChanged"), t)
end

function World.inputObject(keyCode: any?, inputType: any?, state: any?): any
	local io = Rt.newInstance("InputObject")
	Rt.setInternal(io, "KeyCode", keyCode or E.KeyCode.Unknown)
	Rt.setInternal(io, "UserInputType", inputType or E.UserInputType.Keyboard)
	Rt.setInternal(io, "UserInputState", state or E.UserInputState.Begin)
	Rt.setInternal(io, "Position", V3.new(World.mouse.X, World.mouse.Y, 0))
	return io
end

-- Dispatches one key transition through ContextActionService bindings
-- (priority order, Sink stops), then the engine's ProximityPrompt keys, then
-- UserInputService.InputBegan / InputEnded.
function World.dispatchKey(keyCode: any, inputType: any?, state: any)
	local uis = World.services.UserInputService
	local itype = inputType or E.UserInputType.Keyboard
	local io = World.inputObject(keyCode, itype, state)
	local list = {}
	for _, b in World.cas do
		for _, k in b.inputs do
			if k == keyCode or k == itype then
				table.insert(list, b)
				break
			end
		end
	end
	table.sort(list, function(a, b)
		if a.priority == b.priority then
			return a.seq > b.seq
		end
		return a.priority > b.priority
	end)
	local sunk = false
	for _, b in list do
		local result = nil
		Sched.spawn(function()
			result = b.fn(b.name, state, io)
		end)
		if result == E.ContextActionResult.Sink or result == nil then
			sunk = true
			break
		end
	end
	if not sunk then
		World.promptKey(keyCode, itype, state)
	end
	Rt.fire(Rt.getSignal(uis, if state == E.UserInputState.Begin then "InputBegan" else "InputEnded"), io, sunk)
	Sched.flushDeferred()
end

function World.keyDown(keyCode: any, inputType: any?)
	World.dispatchKey(keyCode, inputType, E.UserInputState.Begin)
end

function World.keyUp(keyCode: any, inputType: any?)
	World.dispatchKey(keyCode, inputType, E.UserInputState.End)
end

function World.pressKey(keyCode: any, inputType: any?)
	World.keyDown(keyCode, inputType)
	World.keyUp(keyCode, inputType)
end

-- ProximityPromptService stand-in. Each frame: a prompt is shown when it is
-- Enabled, a descendant of workspace, within MaxActivationDistance of the
-- character's HumanoidRootPart and on screen; Exclusivity OnePerButton keeps
-- the nearest per key, OneGlobally the nearest overall, MaxPromptsVisible
-- caps the rest. RequiresLineOfSight is ignored (no physics). Changes fire
-- PromptShown(prompt, inputType) / PromptHidden like the engine.
World.promptsShown = {} :: { [any]: any }
World.promptEngine = true

local function promptPos(p: any): any
	local par = p.Parent
	if not par then
		return nil
	end
	local pr = recs[par]
	if Api.isA(pr.class, "BasePart") then
		return par.Position
	elseif pr.class == "Attachment" then
		return par.WorldPosition
	elseif Api.isA(pr.class, "Model") then
		return par:GetPivot().Position
	end
	return nil
end

function World.promptInputType(): any
	local t = World.lastInputType
	if t == E.UserInputType.Touch then
		return E.ProximityPromptInputType.Touch
	elseif t == E.UserInputType.Gamepad1 then
		return E.ProximityPromptInputType.Gamepad
	end
	return E.ProximityPromptInputType.Keyboard
end

function World.promptStep()
	if not World.promptEngine then
		return
	end
	local pps = World.services.ProximityPromptService
	local char = World.character
	local root = char and recs[char] and not recs[char].destroyed and char:FindFirstChild("HumanoidRootPart")
	local input = World.promptInputType()
	local want = {}
	if root and pps.Enabled ~= false then
		local rp = root.Position
		local cands = {}
		Rt.eachDescendant(recs[World.workspace], function(d)
			if d.class == "ProximityPrompt" and not d.destroyed then
				local p = d.proxy
				if p.Enabled then
					local pos = promptPos(p)
					if pos then
						local dist = (pos - rp).Magnitude
						if dist <= p.MaxActivationDistance then
							local _, on = project(World.camera, pos)
							if on then
								table.insert(cands, { p = p, d = dist })
							end
						end
					end
				end
			end
		end)
		table.sort(cands, function(a, b)
			return a.d < b.d
		end)
		local perKey, global = {}, false
		local count = 0
		local maxVisible = pps.MaxPromptsVisible or 16
		for _, c in cands do
			local p = c.p
			local ex = p.Exclusivity
			local key = if input == E.ProximityPromptInputType.Gamepad then p.GamepadKeyCode else p.KeyboardKeyCode
			local ok = true
			if ex == E.ProximityPromptExclusivity.OnePerButton then
				ok = not perKey[key]
				perKey[key] = true
			elseif ex == E.ProximityPromptExclusivity.OneGlobally then
				ok = not global
				global = true
			end
			if ok and count < maxVisible then
				want[p] = true
				count += 1
			end
		end
	end
	for p, shownInput in table.clone(World.promptsShown) do
		if not want[p] or shownInput ~= input then
			World.promptsShown[p] = nil
			Rt.fire(Rt.getSignal(pps, "PromptHidden"), p)
			Rt.fire(Rt.getSignal(p, "PromptHidden"))
		end
	end
	for p in want do
		if not World.promptsShown[p] then
			World.promptsShown[p] = input
			Rt.fire(Rt.getSignal(pps, "PromptShown"), p, input)
			Rt.fire(Rt.getSignal(p, "PromptShown"), input)
		end
	end
	Sched.flushDeferred()
end

-- the engine binds each shown prompt's key
function World.promptKey(keyCode: any, inputType: any, state: any)
	local gamepad = string.find(tostring(inputType), "Gamepad", 1, true) ~= nil
	for p in table.clone(World.promptsShown) do
		local key = if gamepad then p.GamepadKeyCode else p.KeyboardKeyCode
		if key == keyCode then
			if state == E.UserInputState.Begin then
				p:InputHoldBegin()
			else
				p:InputHoldEnd()
			end
		end
	end
end

-- Default camera scripts (PlayerModule) stand-in: while the camera is not
-- Scriptable it follows the head, and in first person it re-locks the mouse
-- every frame, exactly the behaviour the game's seated camera must beat.
local function cameraScripts()
	if not World.opts.cameraScripts then
		return
	end
	local cam = World.camera
	if cam.CameraType == E.CameraType.Scriptable then
		return
	end
	local char = World.character
	local head = char and recs[char] and not recs[char].destroyed and char:FindFirstChild("Head")
	if head then
		local hp = head.Position
		cam.CFrame = CF.new(hp.X, hp.Y, hp.Z) * rotationOf(head.CFrame)
	end
	local player = World.player
	local uis = World.services.UserInputService
	if player.CameraMode == E.CameraMode.LockFirstPerson or player.CameraMaxZoomDistance <= 0.5 then
		if uis.MouseBehavior ~= E.MouseBehavior.LockCenter then
			uis.MouseBehavior = E.MouseBehavior.LockCenter
		end
	end
end

World.layoutPasses = 0
function World.layout()
	for _ = 1, 4 do
		if not Rt.layoutDirty then
			break
		end
		Rt.layoutDirty = false
		Layout.pass(World.playerGui)
		World.layoutPasses += 1
		Rt.layoutDirty = false
		Sched.flushDeferred()
	end
end

-- One engine frame.
function World.step(dt: number?)
	local d = dt or (1 / 60)
	Sched.frame += 1
	Sched.advance(d)
	Sched.flushDeferred()
	local rs = World.services.RunService
	-- render step: camera scripts at Camera priority, then bound callbacks by priority
	local bindings = table.clone(World.renderBindings)
	table.insert(bindings, { name = "__camera", priority = 200, fn = cameraScripts })
	table.sort(bindings, function(a, b)
		return a.priority < b.priority
	end)
	for _, b in bindings do
		Sched.spawn(b.fn, d)
	end
	Rt.fire(Rt.getSignal(rs, "PreRender"), d)
	Rt.fire(Rt.getSignal(rs, "RenderStepped"), d)
	Sched.flushDeferred()
	World.layout()
	Rt.fire(Rt.getSignal(rs, "PreAnimation"), d)
	Rt.fire(Rt.getSignal(rs, "PreSimulation"), d)
	Rt.fire(Rt.getSignal(rs, "Stepped"), Sched.now, d)
	Rt.fire(Rt.getSignal(rs, "PostSimulation"), d)
	Rt.fire(Rt.getSignal(rs, "Heartbeat"), d)
	Sched.flushDeferred()
	World.promptStep()
end

function World.run(seconds: number, dt: number?)
	local d = dt or (1 / 30)
	local n = math.max(1, math.ceil(seconds / d))
	for _ = 1, n do
		World.step(d)
	end
end

return World
