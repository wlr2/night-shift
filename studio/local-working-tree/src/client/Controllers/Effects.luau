--!strict
-- Cosmetic reactions to server Fx cues: sounds, flickers, monitor wake-ups,
-- the chase alert, colour stings. The server already decided everything;
-- this only makes it readable and felt.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Layout = require(ReplicatedStorage.Shared.Layout)
local State = require(script.Parent.State)
local Atmosphere = require(script.Parent.Atmosphere)
local Hud = require(script.Parent.Hud)
local Sfx = require(script.Parent.Parent.Ui.Sfx)

local player = Players.LocalPlayer

local Effects = {}

local DOOR_POS = Vector3.new(Layout.REAR_DOOR.x, 3.5, (Layout.REAR_DOOR.minZ + Layout.REAR_DOOR.maxZ) / 2)

local function sting(color: Color3, seconds: number)
	local cc = Atmosphere.cc()
	local base = cc.TintColor
	cc.TintColor = color
	TweenService:Create(cc, TweenInfo.new(seconds, Enum.EasingStyle.Sine), { TintColor = base }):Play()
end

local function interactive(name: string): BasePart?
	local map = workspace:FindFirstChild("Map")
	local inter = map and map:FindFirstChild("Interactive")
	local p = inter and inter:FindFirstChild(name)
	return if p and p:IsA("BasePart") then p else nil
end

local function monitorWake(desk: number, text: string, seconds: number)
	local screen = interactive("SourceScreen_" .. desk)
	if not screen then
		return
	end
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Back
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 80
	sg.LightInfluence = 0
	sg.Brightness = 1.5
	sg.Parent = screen
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundColor3 = Color3.fromRGB(10, 30, 60)
	t.TextColor3 = Color3.fromRGB(220, 230, 255)
	t.Font = Enum.Font.Arcade
	t.TextScaled = true
	t.Text = text
	t.Parent = sg
	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(120, 150, 255)
	glow.Range = 7
	glow.Brightness = 0.8
	glow.Parent = screen
	Sfx.play("chime", { pos = screen.Position, volume = 0.3, speed = 0.6 })
	task.delay(seconds, function()
		sg:Destroy()
		glow:Destroy()
	end)
end

local handlers: { [string]: (data: any) -> () } = {
	PowerWarning = function(data)
		Atmosphere.flicker(data.seconds or 4, 0.4)
	end,
	LightFlicker = function(data)
		Atmosphere.flicker(data.seconds or 1.5, 0.3)
	end,
	PowerOff = function()
		Sfx.play("breaker", { volume = 0.8, speed = 0.7 })
		sting(Color3.fromRGB(190, 200, 255), 2)
	end,
	BreakerReset = function()
		Sfx.play("breaker", { volume = 0.6 })
	end,
	DoorUnlatched = function()
		Sfx.play("chime", { pos = DOOR_POS, volume = 0.9, speed = 0.8 })
		Sfx.play("doorSlam", { pos = DOOR_POS, volume = 0.4, speed = 1.3 })
	end,
	DoorOpened = function()
		Sfx.play("doorSlam", { pos = DOOR_POS, volume = 0.3, speed = 1.4 })
	end,
	DoorLatched = function()
		Sfx.play("doorSlam", { pos = DOOR_POS, volume = 0.7 })
	end,
	DoorKnock = function()
		for i = 0, 2 do
			task.delay(i * 0.45, function()
				Sfx.play("knock", { pos = DOOR_POS, volume = 1, speed = 0.8 })
			end)
		end
	end,
	FrontKnock = function()
		local p = Vector3.new(13, 3.5, Layout.FRONT_DOOR.z + 1)
		for i = 0, 1 do
			task.delay(i * 0.5, function()
				Sfx.play("knock", { pos = p, volume = 0.8, speed = 0.9 })
			end)
		end
	end,
	FigureApproach = function()
		sting(Color3.fromRGB(255, 200, 190), 3)
		Sfx.play("footsteps", { pos = Layout.THREAT_ROUTE[2], volume = 0.6, speed = 0.7, duration = 6 })
	end,
	FigureInside = function()
		sting(Color3.fromRGB(255, 170, 160), 4)
		Atmosphere.flicker(1.2, 0.3)
	end,
	FigurePeek = function()
		sting(Color3.fromRGB(230, 220, 255), 2.5)
	end,
	CrewSeen = function()
		sting(Color3.fromRGB(220, 230, 255), 4)
		Atmosphere.flicker(0.8, 0.2)
	end,
	ChaseStart = function(data)
		if data.target == player.UserId then
			Hud.toast("RUN! Back inside through the rear door!", "bad")
		end
		sting(Color3.fromRGB(255, 150, 140), 5)
	end,
	MonitorWake = function(data)
		monitorWake(data.desk, data.text, data.seconds or 6)
	end,
	PrinterWake = function()
		local led = interactive("PrinterLed")
		Sfx.play("phone", { pos = Layout.PRINTER, volume = 0.4, speed = 0.5 })
		if led then
			task.spawn(function()
				for _ = 1, 8 do
					led.Transparency = 0.7
					task.wait(0.15)
					led.Transparency = 0
					task.wait(0.15)
				end
			end)
		end
	end,
	ChairShift = function(data)
		Sfx.play("doorSlam", { pos = data.pos, volume = 0.25, speed = 1.8 })
	end,
	FootstepsStop = function(data)
		Sfx.play("footsteps", { pos = data.pos, volume = 0.7, speed = 0.8, duration = 2.6 })
	end,
	PhoneRing = function(data)
		for i = 0, 1 do
			task.delay(i * 1.2, function()
				Sfx.play("phone", { pos = data.pos, volume = 0.6, speed = 1.0 })
			end)
		end
	end,
	DesktopSound = function(data)
		if data.kind == "bad" then
			Sfx.play("error", { volume = 0.4, speed = 0.55 })
		elseif data.kind == "stage" or data.kind == "complete" then
			Sfx.play("chime", { volume = 0.5, speed = 1.2 })
		end
	end,
	DriveDocked = function()
		Sfx.play("click", { pos = Layout.WORKSTATION.dock, volume = 0.6, speed = 0.8 })
	end,
	DriveErased = function(data)
		Sfx.play("chime", { pos = Layout.WORKSTATION.dock, volume = 0.6, speed = 0.9 })
		Hud.toast(string.format("%s securely erased (%d/6).", data.id, data.count), "good")
	end,
	PcShutdown = function()
		Sfx.play("click", { volume = 0.3, speed = 0.6 })
	end,
	Downed = function(data)
		sting(Color3.fromRGB(255, 120, 120), 2)
		local _ = data
	end,
	Revived = function(data)
		Hud.toast(data.name .. " is back on their feet" .. (if data.by then " (thanks to " .. data.by .. ")" else "") .. ".", "good")
	end,
	FinalPurge = function()
		sting(Color3.fromRGB(255, 140, 130), 6)
		Atmosphere.flicker(2.5, 0.35)
		Hud.toast("FINAL PURGE queued. Your own records are on the list. Get to the workstation!", "bad")
	end,
	PurgeExecuted = function()
		Atmosphere.flicker(2, 0.6)
	end,
	SignOffStart = function()
		Hud.toast("Emergency sign-off running. Keep the power on and confirm checkpoints.", "info")
	end,
	SignOffConfirm = function()
		Sfx.play("chime", { pos = Layout.WORKSTATION.monitor, volume = 0.8, speed = 0.7 })
	end,
	ClockOutStart = function()
		sting(Color3.fromRGB(255, 170, 150), 6)
		Hud.toast("Sign-off complete. CLOCK OUT at the lobby time clock and get out!", "good")
	end,
	ClockedOut = function(data)
		Hud.toast(data.name .. " clocked out.", "info")
	end,
	FrontDoorOpen = function()
		Hud.toast("The front door is open. Go!", "good")
	end,
	TrashThrown = function()
		Sfx.play("doorSlam", { pos = Layout.DUMPSTER, volume = 0.6, speed = 0.7 })
	end,
}

-- hide the revive prompt that belongs to our own character
local function hideOwnPrompts()
	game:GetService("ProximityPromptService").PromptShown:Connect(function(prompt)
		if prompt:GetAttribute("OwnerUserId") == player.UserId then
			prompt.Enabled = false
		end
	end)
end

function Effects.init()
	State.Fx:Connect(function(name, data)
		local h = handlers[name]
		if h then
			local ok, err = pcall(h :: any, data)
			if not ok then
				warn("[Effects]", name, err)
			end
		end
	end)
	hideOwnPrompts()
end

return Effects
