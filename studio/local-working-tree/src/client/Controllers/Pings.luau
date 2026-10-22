--!strict
-- Team pings (no voice needed): G / gamepad Y / on-screen button marks the
-- spot under the cursor/centre of screen for everyone for a few seconds.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local State = require(script.Parent.State)
local Desktop = require(script.Parent.Desktop)
local Sfx = require(script.Parent.Parent.Ui.Sfx)

local player = Players.LocalPlayer

local Pings = {}

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
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(160, 54)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 200
	bb.Parent = part
	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(18, 18)
	dot.Position = UDim2.new(0.5, -9, 1, -18)
	dot.BackgroundColor3 = Color3.fromRGB(255, 210, 60)
	dot.BorderSizePixel = 0
	dot.Parent = bb
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = dot
	local t = Instance.new("TextLabel")
	t.Size = UDim2.new(1, 0, 0, 34)
	t.BackgroundTransparency = 1
	t.TextColor3 = Color3.fromRGB(255, 230, 140)
	t.TextStrokeTransparency = 0.3
	t.Font = Enum.Font.ArialBold
	t.TextScaled = true
	t.Text = by .. " pinged (" .. where .. ")"
	t.Parent = bb
	Sfx.play("click", { pos = pos, volume = 0.5, speed = 1.4 })
	task.delay(Config.PING.lifetime, function()
		part:Destroy()
	end)
end

function Pings.init()
	ContextActionService:BindAction("NS_Ping", doPing, true, Enum.KeyCode.G, Enum.KeyCode.ButtonY)
	ContextActionService:SetTitle("NS_Ping", "Ping")
	ContextActionService:SetPosition("NS_Ping", UDim2.new(1, -170, 1, -150))
	State.Pinged:Connect(showPing)
end

return Pings
