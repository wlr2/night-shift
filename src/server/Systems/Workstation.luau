--!strict
-- The shared corner workstation: one server-owned session at a time.
--  * Only the seated operator of the CURRENT session id may act.
--  * Standing, death, disconnect, reset or being caught ends the session.
--  * A new operator receives the current authoritative puzzle state.
--  * Actions carrying an old session id are rejected.
-- Other systems add desktop commands with Workstation.registerCommand.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Fonts = require(ReplicatedStorage.Shared.Fonts)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Types = require(ReplicatedStorage.Shared.Types)
local Server = script.Parent.Parent
local Guard = require(Server.Util.Guard)
local Prompts = require(Server.Util.Prompts)
local Minigames = require(Server.Minigames)
local GameState = require(script.Parent.GameState)
local MapBuilder = require(script.Parent.MapBuilder)
local Power = require(script.Parent.Power)
local Drives = require(script.Parent.Drives)

local Workstation = {}

local operator: Player? = nil
local sessionId = 0
local lastFeedback: { text: string?, kind: string? } = {}
local phantom: { id: number, x: number, y: number, first: boolean }? = nil
local sitPrompt: ProximityPrompt
local screenText: TextLabel
local screenSub: TextLabel

Workstation.SessionStarted = Signal.new() :: Signal.Signal<Player>
Workstation.SessionEnded = Signal.new() :: Signal.Signal<Player>
Workstation.ActionPerformed = Signal.new() :: Signal.Signal<Player, string>

type CommandHandler = (player: Player, a: any, b: any) -> (string?, string?)
local commands: { [string]: CommandHandler } = {}

function Workstation.registerCommand(kind: string, handler: CommandHandler)
	commands[kind] = handler
end

function Workstation.operator(): Player?
	return operator
end

function Workstation.sessionId(): number
	return sessionId
end

function Workstation.setPhantom(p: { id: number, x: number, y: number, first: boolean }?)
	phantom = p
	Workstation.push()
end

local function payload(reason: string?): Types.SessionPayload
	local d = Drives.dockDrive()
	local job = d and d.job
	local p: Types.SessionPayload = {
		active = operator ~= nil,
		sessionId = sessionId,
		driveId = if d then d.id else nil,
		driveName = if d then d.name else nil,
		game = if d then d.game else nil,
		title = nil,
		instructions = nil,
		stage = 0,
		stages = 0,
		progress = 0,
		view = nil,
		feedback = lastFeedback.text,
		feedbackKind = lastFeedback.kind,
		hint = nil,
		transitioning = false,
		phantom = phantom,
		reason = reason,
	}
	if d then
		local g = Minigames.get(d.game)
		if g then
			p.title = g.title
			p.instructions = g.instructions
		end
	end
	if job and d and d.state == "Processing" then
		local view, hint = Minigames.view(job)
		p.view = view
		p.hint = hint
		p.stage = job.state.stage
		p.stages = job.state.stages
		p.progress = Minigames.progress(job)
		p.transitioning = view.transitioning == true
	end
	if not Power.workstationOn() then
		p.reason = "power"
	end
	return p
end

local function updateScreen()
	local d = Drives.dockDrive()
	local text, sub
	if not Power.workstationOn() then
		text, sub = "NO POWER", "reset breaker in utility hall"
	elseif GameState.phase == "SignOff" and GameState.data.signOff then
		text = string.format("SIGN-OFF %d%%", math.floor(GameState.data.signOff.progress * 100))
		sub = if GameState.data.signOff.awaiting then "CONFIRMATION NEEDED" else "do not power down"
	elseif GameState.phase == "FinalPurge" then
		text, sub = "FINAL PURGE QUEUE", "!! cancel your records !!"
	elseif d and d.job then
		text = string.format("%s  %d%%", d.id, math.floor(Minigames.progress(d.job) * 100))
		sub = string.format("stage %d/%d  %s", d.job.state.stage, d.job.state.stages, if operator then "op: " .. operator.DisplayName else "no operator")
	elseif d then
		text, sub = d.id .. " DOCKED", "sit down to start SecureErase"
	else
		text, sub = string.format("ERASED %d/%d", GameState.data.erased, Config.DRIVE_COUNT), "dock the next drive"
	end
	screenText.Text = text
	screenSub.Text = sub
end

function Workstation.push(reason: string?)
	updateScreen()
	if operator then
		Net.remote("Session"):FireClient(operator, payload(reason))
	end
	GameState.markDirty()
end

local function endSession(why: string?)
	local old = operator
	if not old then
		return
	end
	operator = nil
	sessionId += 1 -- invalidates any in-flight action from the old session
	Net.remote("Session"):FireClient(old, { active = false, sessionId = sessionId, reason = why } :: any)
	sitPrompt.Enabled = true
	sitPrompt.ObjectText = "Corner workstation"
	updateScreen()
	GameState.markDirty()
	Workstation.SessionEnded:Fire(old)
end

local function forceStand(player: Player)
	local seat = MapBuilder.refs.seat
	local weld = seat:FindFirstChild("SeatWeld")
	if weld then
		weld:Destroy()
	end
	local h = Guard.humanoidOf(player)
	if h then
		h.Sit = false
		h.Jump = true
	end
end

function Workstation.kick(player: Player, why: string?)
	if operator == player then
		forceStand(player)
		endSession(why)
	end
end

local function startSession(player: Player)
	operator = player
	sessionId += 1
	lastFeedback = {}
	sitPrompt.Enabled = false
	sitPrompt.ObjectText = "Occupied by " .. player.DisplayName
	local d = Drives.dockDrive()
	if d and d.state == "Processing" then
		lastFeedback = { text = "Resumed " .. d.id .. " at stage " .. (if d.job then d.job.state.stage else 1) .. ".", kind = "info" }
	end
	Workstation.push()
	Workstation.SessionStarted:Fire(player)
end

local function onOccupant()
	local seat = MapBuilder.refs.seat
	local occ = seat.Occupant
	if occ == nil then
		endSession("stood up")
		return
	end
	local player = Players:GetPlayerFromCharacter(occ.Parent)
	if not player or player:GetAttribute("Downed") == true or (operator and operator ~= player) then
		-- not a valid operator: eject immediately
		local weld = seat:FindFirstChild("SeatWeld")
		if weld then
			weld:Destroy()
		end
		return
	end
	if operator ~= player then
		startSession(player)
	end
end

-- Puzzle actions --------------------------------------------------------------

local ACTIONS: { [string]: boolean } = {
	sort = true,
	swap = true,
	rotate = true,
	match = true,
	press = true,
	replay = true,
	kill = true,
	purge = true,
}

local function validArg(v: unknown): boolean
	local t = typeof(v)
	if t == "nil" then
		return true
	elseif t == "number" then
		local n = v :: number
		return n == n and math.abs(n) < 1e6
	elseif t == "string" then
		return #(v :: string) <= 32
	end
	return false
end

local function doPuzzle(player: Player, action: string, a: any, b: any)
	local d = Drives.dockDrive()
	if not d or d.state ~= "Processing" or not d.job then
		return
	end
	local job = d.job
	local res = Minigames.perform(job, action, a, b)
	if res.message ~= "" then
		lastFeedback = { text = res.message, kind = if res.kind == "bad" then "bad" elseif res.kind == "info" then "info" else "good" }
	end
	GameState.fx("DesktopSound", { kind = res.kind }, player)
	Workstation.ActionPerformed:Fire(player, res.kind)
	if res.kind == "complete" then
		lastFeedback = { text = d.id .. " securely erased.", kind = "good" }
		Drives.markErased(d)
	elseif res.kind == "stage" then
		task.delay(Config.STAGE_TRANSITION_SECONDS + 0.05, function()
			Workstation.push()
		end)
	end
	Workstation.push()
end

local function onDesktop(player: Player, sid: unknown, kind: unknown, a: unknown, b: unknown, c: unknown)
	local rate = Config.RATE.desktop
	if not Guard.allow(player, "desktop", rate[1], rate[2]) then
		return
	end
	if typeof(sid) ~= "number" or typeof(kind) ~= "string" or #(kind :: string) > 24 then
		return
	end
	if not validArg(a) or not validArg(b) or not validArg(c) then
		return
	end
	-- session authority: the player must be THE seated operator of THIS session
	if player ~= operator or sid ~= sessionId then
		if typeof(player) == "Instance" then -- (QA harness actors are not Players)
			Net.remote("Session"):FireClient(player, { active = player == operator, sessionId = sessionId, reason = "stale" } :: any)
		end
		return
	end
	local seat = MapBuilder.refs.seat
	local h = Guard.humanoidOf(player)
	if not h or seat.Occupant ~= h then
		endSession("not seated")
		return
	end
	if kind == "refresh" then
		Workstation.push()
		return
	end
	if not Power.workstationOn() then
		Workstation.push("power")
		return
	end
	if kind == "start" then
		local d = Drives.dockDrive()
		if d then
			Drives.beginProcessing(d)
			lastFeedback = { text = "SecureErase started on " .. d.id .. ".", kind = "info" }
		end
		Workstation.push()
	elseif kind == "act" then
		if typeof(a) ~= "string" or not ACTIONS[a :: string] then
			return
		end
		doPuzzle(player, a :: string, b, c)
	else
		local handler = commands[kind :: string]
		if handler then
			local text, fkind = handler(player, a, b)
			if text then
				lastFeedback = { text = text, kind = fkind or "info" }
			end
			Workstation.push()
		end
	end
end

-- QA-only entry point (Studio harness in Cheats): the same handler the
-- Desktop remote uses, callable with a simulated actor.
Workstation.handleDesktop = function(player: any, sid: unknown, kind: unknown, a: unknown, b: unknown, c: unknown)
	onDesktop(player, sid, kind, a, b, c)
end

function Workstation.init()
	local refs = MapBuilder.refs
	-- physical monitor: simplified progress for teammates
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Back
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 90
	sg.LightInfluence = 0
	sg.Brightness = 1.4
	sg.Parent = refs.monitorScreen
	screenText = Instance.new("TextLabel")
	screenText.Size = UDim2.fromScale(1, 0.55)
	screenText.BackgroundTransparency = 1
	screenText.TextColor3 = Color3.fromRGB(176, 224, 168) -- soft green phosphor
	screenText.FontFace = Fonts.PIXEL_BOLD
	screenText.TextScaled = true
	screenText.Parent = sg
	screenSub = Instance.new("TextLabel")
	screenSub.Size = UDim2.fromScale(1, 0.35)
	screenSub.Position = UDim2.fromScale(0, 0.6)
	screenSub.BackgroundTransparency = 1
	screenSub.TextColor3 = Color3.fromRGB(126, 176, 128)
	screenSub.FontFace = Fonts.PIXEL
	screenSub.TextScaled = true
	screenSub.Parent = sg

	sitPrompt = Prompts.make(refs.seatPromptPart, {
		action = "Sit down",
		object = "Corner workstation",
		distance = Config.REACH.workstation,
		hold = 0.2,
	})
	sitPrompt.Triggered:Connect(function(player)
		if not Prompts.valid(player, sitPrompt, "sit") then
			return
		end
		if operator then
			GameState.notify(player, operator.DisplayName .. " is operating the workstation.", "info")
			return
		end
		if Drives.carrying(player) then
			GameState.notify(player, "Put down what you are carrying first (rack or dock).", "bad")
			return
		end
		local h = Guard.humanoidOf(player)
		if h then
			refs.seat:Sit(h)
		end
	end)

	refs.seat:GetPropertyChangedSignal("Occupant"):Connect(onOccupant)
	Net.remote("Desktop").OnServerEvent:Connect(onDesktop)
	Net.remote("Leave").OnServerEvent:Connect(function(player)
		local rate = Config.RATE.leave
		if not Guard.allow(player, "leave", rate[1], rate[2]) then
			return
		end
		Workstation.kick(player, "left computer")
	end)
	Players.PlayerRemoving:Connect(function(player)
		if operator == player then
			endSession("disconnected")
		end
	end)
	Power.Changed:Connect(function()
		Workstation.push()
	end)
	Drives.StateChanged:Connect(function()
		Workstation.push()
	end)
	GameState.PhaseChanged:Connect(function()
		Workstation.push()
	end)
	GameState.RoundReset:Connect(function()
		phantom = nil
		lastFeedback = {}
		if operator then
			Workstation.kick(operator, "round reset")
		end
	end)
	GameState.providers.operator = function()
		return if operator then operator.DisplayName else nil
	end
	updateScreen()
end

function Workstation.start()
	-- slow refresh keeps the physical monitor and the operator view honest
	while true do
		task.wait(1)
		if operator and (operator.Parent == nil or not Guard.alive(operator)) then
			endSession("operator lost")
		end
		updateScreen()
	end
end

return Workstation
