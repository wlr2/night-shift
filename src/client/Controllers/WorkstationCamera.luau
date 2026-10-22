--!strict
-- First-person play, the seated workstation camera, and the one place that
-- turns Ui/Cursor state into real mouse behaviour.
--
-- Walking: StarterPlayer locks the camera to first person (LockFirstPerson,
-- zoom 0.5). The PlayerModule camera re-locks the mouse to the centre every
-- frame and its TransparencyController hides the local body, so the head
-- never shows. The cursor icon is hidden; the HUD draws a dot.
-- Seated: a Scriptable camera eases from the head to a framing of the
-- physical monitor (the room is behind you - that is the point). Scriptable
-- switches the PlayerModule camera controller off, so nothing re-locks the
-- free pointer the desktop needs.
-- Leaving (Leave button, Space / gamepad B), losing the seat, death,
-- respawn, being caught or a server-ended session restores first person at
-- once, without easing.
--
-- Pointer: free and visible whenever Cursor.isFree(), we are seated or the
-- desktop is open. Seated, MouseBehavior is simply Default. If UI frees the
-- pointer while walking, a hidden Modal button makes the engine release the
-- lock; overwriting MouseBehavior after the PlayerModule every frame would
-- warp the cursor to the centre each frame. player.CameraMode is never
-- toggled: changing it re-activates a camera controller even while the
-- camera is Scriptable, and with zoom clamped to 0.5 Classic is first person
-- (mouse locked) anyway.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Layout = require(ReplicatedStorage.Shared.Layout)
local State = require(script.Parent.State)
local Desktop = require(script.Parent.Desktop)
local Cursor = require(script.Parent.Parent.Ui.Cursor)

local player = Players.LocalPlayer

local WorkstationCamera = {}

local WALK_FOV = 70
-- Seated framing from Layout.WORKSTATION: aim at the screen centre, eye back
-- along the facing and a little above it. That puts the eye in open air
-- (>= 1.45 studs from chair, keyboard, monitor and desk, ~4 from both walls)
-- and, at FOV 50, keeps the physical monitor inside the desktop's bezel on
-- 4:3 to 21:9 screens so no second monitor edge peeks out beside it.
local SEAT_FOV = 50
local AIM_UP = 1.2 -- above the monitor base: screen centre height
local EYE_BACK = 3.3
local EYE_UP = 0.42
local EASE_IN = 0.35 -- seconds from the seated head to the monitor framing
local STEP_NAME = "NS_FirstPersonCamera"
local STEP_PRIORITY = Enum.RenderPriority.Camera.Value + 1 -- after the PlayerModule camera

local active = false
local easeFrom: CFrame? = nil
local easeFov = WALK_FOV
local engagedAt = 0
local touchHidden = false
local modal: TextButton? = nil

local function seatedCFrame(t: number): CFrame
	local W = Layout.WORKSTATION
	local target = W.monitor + Vector3.new(0, AIM_UP, 0)
	local eye = target - W.facing * EYE_BACK + Vector3.new(0, EYE_UP, 0)
	-- slow breathing sway, tiny so the edges around the desktop barely move
	local right = W.facing:Cross(Vector3.yAxis)
	local sway = right * (math.sin(t * 0.6) * 0.02) + Vector3.yAxis * (math.sin(t * 0.9) * 0.015)
	return CFrame.lookAt(eye + sway, target)
end

local function humanoid(): Humanoid?
	local character = player.Character
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

local function pointerFree(): boolean
	return active or Cursor.isFree() or Desktop.isOpen()
end

local function applyPointer()
	local free = pointerFree()
	if modal then
		modal.Visible = free
	end
	-- touch: the thumbstick and jump button sit under the desktop and would
	-- take taps meant for it (a stray jump stands you up); Leave is on screen
	local hideTouch = Desktop.isOpen()
	if hideTouch ~= touchHidden then
		touchHidden = hideTouch
		GuiService.TouchControlsEnabled = not hideTouch
	end
	if GuiService.MenuIsOpen then
		-- the Roblox menu owns the pointer while it is up
		if not UserInputService.MouseIconEnabled then
			UserInputService.MouseIconEnabled = true
		end
		return
	end
	local scripted = workspace.CurrentCamera.CameraType == Enum.CameraType.Scriptable
	if free then
		if not UserInputService.MouseIconEnabled then
			UserInputService.MouseIconEnabled = true
		end
		if scripted and UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
	else
		if UserInputService.MouseIconEnabled then
			UserInputService.MouseIconEnabled = false
		end
		if not scripted and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		end
	end
end

local function step()
	if active then
		local cam = workspace.CurrentCamera
		if cam.CameraType ~= Enum.CameraType.Scriptable then
			cam.CameraType = Enum.CameraType.Scriptable -- e.g. a replaced camera: keep the framing
		end
		local now = os.clock()
		local goal = seatedCFrame(now)
		local a = (now - engagedAt) / EASE_IN
		local from = easeFrom
		if from and a < 1 then
			local k = 1 - (1 - a) * (1 - a)
			cam.CFrame = from:Lerp(goal, k)
			cam.FieldOfView = easeFov + (SEAT_FOV - easeFov) * k
		else
			easeFrom = nil
			cam.CFrame = goal
			if cam.FieldOfView ~= SEAT_FOV then
				cam.FieldOfView = SEAT_FOV
			end
		end
	elseif Cursor.has("desktop") and not Desktop.isOpen() then
		-- a leaked desktop request must never leave a walker with a free cursor
		Cursor.request("desktop", false)
	end
	applyPointer()
end

local function engage()
	if active then
		return
	end
	local h = humanoid()
	if not h or h.Health <= 0 or player:GetAttribute("Downed") == true then
		return -- stale session for a dead or caught character: the server ends it
	end
	active = true
	local cam = workspace.CurrentCamera
	easeFrom = cam.CFrame
	easeFov = cam.FieldOfView
	engagedAt = os.clock()
	cam.CameraType = Enum.CameraType.Scriptable
	Cursor.request("seated", true)
	applyPointer()
end

-- Back to first person at once. `force` also resets a camera we did not
-- know was seated (respawn).
local function restore(force: boolean?)
	local cam = workspace.CurrentCamera
	if active or force then
		active = false
		easeFrom = nil
		cam.CameraType = Enum.CameraType.Custom
		local h = humanoid()
		if h then
			cam.CameraSubject = h
		end
	end
	cam.FieldOfView = WALK_FOV
	-- StarterPlayer sets this; only touched with the camera back on Custom
	if cam.CameraType ~= Enum.CameraType.Scriptable and player.CameraMode ~= Enum.CameraMode.LockFirstPerson then
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	end
	Cursor.request("seated", false)
	applyPointer()
end

local function leaveSeat()
	Desktop.forceClose()
	restore()
end

local function hookCharacter(character: Model)
	local h = character:WaitForChild("Humanoid", 10)
	if h and h:IsA("Humanoid") then
		h.Seated:Connect(function(isSeated)
			if not isSeated then
				leaveSeat()
			end
		end)
		h.Died:Connect(leaveSeat)
	end
end

-- Invisible Modal button: while visible the engine keeps the mouse unlocked
-- even though the first-person camera asks for LockCenter every frame.
local function makeModal(): TextButton
	local gui = Instance.new("ScreenGui")
	gui.Name = "PointerRelease"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	local b = Instance.new("TextButton")
	b.Name = "Modal"
	b.Modal = true
	b.Visible = false
	b.Selectable = false
	b.AutoButtonColor = false
	b.BackgroundTransparency = 1
	b.Text = ""
	b.AnchorPoint = Vector2.new(1, 1)
	b.Position = UDim2.fromScale(1, 1)
	b.Size = UDim2.fromOffset(1, 1)
	b.Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui")
	return b
end

function WorkstationCamera.isActive(): boolean
	return active
end

function WorkstationCamera.init()
	player.CameraMode = Enum.CameraMode.LockFirstPerson
	player.CameraMinZoomDistance = 0.5
	player.CameraMaxZoomDistance = 0.5
	workspace.CurrentCamera.FieldOfView = WALK_FOV
	modal = makeModal()
	State.SessionChanged:Connect(function(payload)
		if payload.active then
			engage()
		else
			restore()
		end
	end)
	Cursor.Changed:Connect(applyPointer)
	GuiService.MenuOpened:Connect(applyPointer)
	GuiService.MenuClosed:Connect(applyPointer)
	player:GetAttributeChangedSignal("Downed"):Connect(function()
		if player:GetAttribute("Downed") == true and active then
			leaveSeat()
		end
	end)
	player.CharacterAdded:Connect(function(c)
		restore(true)
		hookCharacter(c)
	end)
	if player.Character then
		task.spawn(hookCharacter, player.Character)
	end
	RunService:BindToRenderStep(STEP_NAME, STEP_PRIORITY, step)
	applyPointer()
end

return WorkstationCamera
