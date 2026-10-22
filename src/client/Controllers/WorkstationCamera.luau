--!strict
-- Seated camera: looks at the physical monitor while the desktop is open
-- (the room is behind you - that is the point). Standing, the Leave button,
-- death or a server-ended session restores the normal camera and input.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Layout = require(ReplicatedStorage.Shared.Layout)
local State = require(script.Parent.State)
local Desktop = require(script.Parent.Desktop)

local player = Players.LocalPlayer

local WorkstationCamera = {}

local active = false
local saved: { fov: number }? = nil
local swayConn: RBXScriptConnection? = nil

local function seatedCFrame(t: number): CFrame
	local W = Layout.WORKSTATION
	local f = W.facing
	local target = W.monitor + Vector3.new(0, 1.15, 0)
	local eye = target - f * 2.7 + Vector3.new(0, 0.55, 0)
	-- slow breathing sway, tiny so text stays readable
	local sway = Vector3.new(math.sin(t * 0.6) * 0.02, math.sin(t * 0.9) * 0.015, 0)
	return CFrame.lookAt(eye + sway, target)
end

local function restore()
	if not active then
		return
	end
	active = false
	if swayConn then
		swayConn:Disconnect()
		swayConn = nil
	end
	local cam = workspace.CurrentCamera
	local character = player.Character
	local h = character and character:FindFirstChildOfClass("Humanoid")
	cam.CameraType = Enum.CameraType.Custom
	if h then
		cam.CameraSubject = h
	end
	if saved then
		cam.FieldOfView = saved.fov
		saved = nil
	end
	UserInputService.MouseIconEnabled = true
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
end

local function engage()
	if active then
		return
	end
	active = true
	local cam = workspace.CurrentCamera
	saved = { fov = cam.FieldOfView }
	cam.CameraType = Enum.CameraType.Scriptable
	cam.FieldOfView = 55
	UserInputService.MouseIconEnabled = true
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	swayConn = RunService.RenderStepped:Connect(function()
		cam.CFrame = seatedCFrame(os.clock())
	end)
end

local function hookCharacter(character: Model)
	local h = character:WaitForChild("Humanoid", 10)
	if h and h:IsA("Humanoid") then
		h.Seated:Connect(function(isSeated)
			if not isSeated then
				restore()
				Desktop.forceClose()
			end
		end)
		h.Died:Connect(function()
			restore()
			Desktop.forceClose()
		end)
	end
end

function WorkstationCamera.isActive(): boolean
	return active
end

function WorkstationCamera.init()
	State.SessionChanged:Connect(function(payload)
		if payload.active then
			engage()
		else
			restore()
		end
	end)
	player.CharacterAdded:Connect(function(c)
		restore()
		hookCharacter(c)
	end)
	if player.Character then
		hookCharacter(player.Character)
	end
end

return WorkstationCamera
