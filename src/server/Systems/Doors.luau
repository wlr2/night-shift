--!strict
-- Rear service door (Latched / Ajar / Open) and the front exit doors.
-- Any non-latched rear door is an unresolved threat the director tracks.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Types = require(ReplicatedStorage.Shared.Types)
local Server = script.Parent.Parent
local Prompts = require(Server.Util.Prompts)
local GameState = require(script.Parent.GameState)
local MapBuilder = require(script.Parent.MapBuilder)

type DoorState = Types.DoorState

local Doors = {}

local state: DoorState = "Latched"
local unsecuredSince: number? = nil
local prompt: ProximityPrompt
local tween: Tween?
local locked = false -- while the figure holds the door (never blocks latching for long)

Doors.Changed = Signal.new() :: Signal.Signal<DoorState, DoorState, Player?>

local ANGLE: { [DoorState]: number } = { Latched = 0, Ajar = 24, Open = 100 }

function Doors.state(): DoorState
	return state
end

function Doors.unsecuredFor(): number
	return if unsecuredSince then os.clock() - unsecuredSince else 0
end

local function updatePrompt()
	if state == "Latched" then
		prompt.ActionText = "Open door"
		prompt.HoldDuration = 0.3
	else
		prompt.ActionText = "Close & latch"
		prompt.HoldDuration = 1.0
	end
	prompt.Enabled = not locked
end

local function place(animated: boolean)
	local refs = MapBuilder.refs
	local RD = refs.rearDoor
	local width = RD.Size.Z + 0.1
	local height = RD.Size.Y + 0.05
	local target = refs.rearDoorHinge * CFrame.Angles(0, math.rad(ANGLE[state]), 0) * CFrame.new(0, height / 2, width / 2)
	if tween then
		tween:Cancel()
	end
	RD.CanCollide = state == "Latched"
	if animated then
		local t = TweenService:Create(RD, TweenInfo.new(if state == "Latched" then 0.35 else 0.9, Enum.EasingStyle.Quad), { CFrame = target })
		tween = t
		t:Play()
	else
		RD.CFrame = target
	end
	local light = refs.doorLight
	local color = if state == "Latched" then Color3.fromRGB(60, 255, 90) else Color3.fromRGB(255, 50, 40)
	light.Color = color
	light:SetAttribute("Alert", state ~= "Latched")
	local pl = light:FindFirstChildOfClass("PointLight")
	if pl then
		pl.Color = color
	end
end

function Doors.set(new: DoorState, by: Player?)
	local old: DoorState = state :: DoorState
	if old == new then
		return
	end
	state = new
	if new == "Latched" then
		unsecuredSince = nil
		GameState.setThreat("door", nil)
		GameState.fx("DoorLatched", nil)
	else
		if not unsecuredSince then
			unsecuredSince = os.clock()
		end
		GameState.setThreat("door", if new == "Ajar" then "Rear door unlatched" else "Rear door open", true, "Rear door")
		GameState.fx(if new == "Ajar" then "DoorUnlatched" else "DoorOpened", nil)
	end
	place(true)
	updatePrompt()
	GameState.markDirty()
	Doors.Changed:Fire(new, old, by)
end

function Doors.setLocked(v: boolean)
	locked = v
	updatePrompt()
end

function Doors.openFront()
	if GameState.data.frontDoorOpen then
		return
	end
	GameState.data.frontDoorOpen = true
	for i, door in MapBuilder.refs.frontDoors do
		door.CanCollide = false
		local dir = if i == 1 then -1 else 1
		TweenService:Create(door, TweenInfo.new(1.4, Enum.EasingStyle.Sine), {
			CFrame = door.CFrame * CFrame.new(dir * (door.Size.X - 0.2), 0, 0),
		}):Play()
	end
	GameState.fx("FrontDoorOpen", nil)
	GameState.markDirty()
end

function Doors.closeFront()
	GameState.data.frontDoorOpen = false
	local FD = require(ReplicatedStorage.Shared.Layout).FRONT_DOOR
	local half = (FD.maxX - FD.minX) / 2
	for i, door in MapBuilder.refs.frontDoors do
		door.CanCollide = true
		door.CFrame = CFrame.new(FD.minX + (i - 1) * half + half / 2, FD.height / 2, FD.z + 0.5)
	end
end

function Doors.init()
	GameState.providers.door = Doors.state
	prompt = Prompts.make(MapBuilder.refs.doorPromptPart, {
		action = "Open door",
		object = "Rear service door",
		hold = 0.3,
		distance = 9,
	})
	prompt.Triggered:Connect(function(player)
		if not Prompts.valid(player, prompt) then
			return
		end
		if state == "Latched" then
			Doors.set("Open", player)
		else
			Doors.set("Latched", player)
		end
	end)
	GameState.RoundReset:Connect(function()
		locked = false
		state = "Ajar"
		Doors.set("Latched")
		Doors.closeFront()
	end)
	place(false)
	updatePrompt()
end

return Doors
