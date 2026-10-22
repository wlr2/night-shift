--!strict
-- Team pings (no voice needed): G / gamepad Y / on-screen button marks the
-- spot under the cursor/centre of screen for everyone for a few seconds.
-- The marker is a small amber diamond under a dark name plate, and the touch
-- button is a square HUD plate, both in the HUD style (docs/ART_DIRECTION.md).

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local State = require(script.Parent.State)
local Desktop = require(script.Parent.Desktop)
local Sfx = require(script.Parent.Parent.Ui.Sfx)
local UiKit = require(script.Parent.Parent.Ui.UiKit)

local player = Players.LocalPlayer
local C = UiKit.C

local Pings = {}

local FADE_OUT = 0.6

local lastPing = 0

local function aimPoint(): Vector3?
	local cam = workspace.CurrentCamera
	local screenPos: Vector2
	if UserInputService.MouseEnabled and not UserInputService.TouchEnabled then
		screenPos = UserInputService:GetMouseLocation()
	else
		screenPos = cam.ViewportSize / 2
	end
	local ray = cam:ViewportPointToRay(screenPos.X, screenPos.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character :: Instance }
	local hit = workspace:Raycast(ray.Origin, ray.Direction * Config.PING.maxDistance, params)
	return if hit then hit.Position else nil
end

local function doPing(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin or Desktop.isOpen() then
		return Enum.ContextActionResult.Pass
	end
	if os.clock() - lastPing < 1.5 then
		return Enum.ContextActionResult.Sink
	end
	local p = aimPoint()
	if p then
		lastPing = os.clock()
		Net.remote("Ping"):FireServer(p)
	end
	return Enum.ContextActionResult.Sink
end

local function fadeOut(root: Instance, seconds: number)
	local info = TweenInfo.new(seconds)
	for _, d in root:GetDescendants() do
		if d:IsA("TextLabel") then
			TweenService:Create(d, info, { TextTransparency = 1 }):Play()
		elseif d:IsA("Frame") then
			TweenService:Create(d, info, { BackgroundTransparency = 1 }):Play()
		elseif d:IsA("UIStroke") then
			TweenService:Create(d, info, { Transparency = 1 }):Play()
		end
	end
end

local function showPing(pos: Vector3, by: string, where: string)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Position = pos + Vector3.new(0, 1.2, 0)
	part.Parent = workspace
	local bb = UiKit.new("BillboardGui", { Name = "Ping", Size = UDim2.fromOffset(240, 76), AlwaysOnTop = true, MaxDistance = 200, Parent = part }) :: BillboardGui
	-- name plate: who pinged, then the area in pixel caps
	local plate = UiKit.frame({
		Name = "Plate",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -20),
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundColor3 = C.hud,
		BackgroundTransparency = 0.22,
		Parent = bb,
	})
	UiKit.stroke(plate, C.amber, 0.35)
	UiKit.padding(plate, UiKit.SPACE.s, UiKit.SPACE.xs)
	UiKit.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center, Parent = plate })
	UiKit.text("body", { Text = by, Font = UiKit.FONT_BOLD, Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, TextWrapped = false, TextColor3 = C.hudText, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 1, Parent = plate })
	UiKit.text("title", { Text = string.upper(where), Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, TextWrapped = false, TextColor3 = C.amber, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 2, Parent = plate })
	-- diamond over the pinged spot
	local mark = UiKit.frame({ Name = "Mark", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 1, -9), Size = UDim2.fromOffset(10, 10), Rotation = 45, BackgroundColor3 = C.amber, Parent = bb })
	UiKit.stroke(mark, C.hud, 0.2)
	Sfx.play("click", { pos = pos, volume = 0.5, speed = 1.4 })
	task.delay(math.max(0, Config.PING.lifetime - FADE_OUT), function()
		if bb.Parent then
			fadeOut(bb, FADE_OUT)
		end
	end)
	task.delay(Config.PING.lifetime, function()
		part:Destroy()
	end)
end

-- The touch button ContextActionService creates is a round image; restyle it
-- as a square dark HUD plate with a pixel label. Only exists on touch devices.
local function styleTouchButton()
	local b = ContextActionService:GetButton("NS_Ping")
	if not b then
		return
	end
	b.ImageTransparency = 1
	b.BackgroundColor3 = C.hud
	b.BackgroundTransparency = 0.22
	b.BorderSizePixel = 0
	UiKit.stroke(b, C.hudLine, 0.45)
	local title = b:FindFirstChild("ActionTitle")
	if title and title:IsA("TextLabel") then
		title.FontFace = UiKit.FONT_PIXEL_BOLD
		title.TextScaled = false
		title.TextSize = 16
		title.TextColor3 = C.hudText
	end
	b.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			b.BackgroundColor3 = C.hud:Lerp(C.amber, 0.35)
		end
	end)
	b.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			b.BackgroundColor3 = C.hud
		end
	end)
end

function Pings.init()
	ContextActionService:BindAction("NS_Ping", doPing, true, Enum.KeyCode.G, Enum.KeyCode.ButtonY)
	ContextActionService:SetTitle("NS_Ping", "PING")
	ContextActionService:SetPosition("NS_Ping", UDim2.new(1, -170, 1, -150))
	styleTouchButton()
	State.Pinged:Connect(showPing)
end

return Pings
