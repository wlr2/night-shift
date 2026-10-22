--!strict
-- Caught/downed state, teammate rescue, escape, and team-wipe detection.
-- Non-graphic: a caught player slumps in place and needs a teammate's hand.
-- Solo players and full-team wipes go straight to the checkpoint system
-- (via the TeamWiped signal, so this module never requires Checkpoints).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Server = script.Parent.Parent
local Guard = require(Server.Util.Guard)
local Prompts = require(Server.Util.Prompts)
local GameState = require(script.Parent.GameState)
local Workstation = require(script.Parent.Workstation)
local Drives = require(script.Parent.Drives)

local PlayerStatus = {}

PlayerStatus.TeamWiped = Signal.new() :: Signal.Signal<string>
PlayerStatus.Downed = Signal.new() :: Signal.Signal<Player>
PlayerStatus.Revived = Signal.new() :: Signal.Signal<Player>

local revivePrompts: { [Player]: ProximityPrompt } = {}
local wipePending = false

function PlayerStatus.isDowned(p: Player): boolean
	return p:GetAttribute("Downed") == true
end

-- players inside the building who can still act
function PlayerStatus.standing(): { Player }
	local out = {}
	for _, p in GameState.activePlayers() do
		if not PlayerStatus.isDowned(p) and Guard.alive(p) then
			table.insert(out, p)
		end
	end
	return out
end

local function setMobility(p: Player, enabled: boolean)
	local h = Guard.humanoidOf(p)
	if h then
		h.WalkSpeed = if enabled then 16 else 0
		h.JumpHeight = if enabled then 7.2 else 0
		h.UseJumpPower = false
	end
end

local function checkWipe()
	if wipePending then
		return
	end
	local active = GameState.activePlayers()
	if #active == 0 then
		return
	end
	local anyStanding = #PlayerStatus.standing() > 0
	local anyDowned = false
	for _, p in active do
		if PlayerStatus.isDowned(p) then
			anyDowned = true
		end
	end
	local solo = #Players:GetPlayers() <= 1
	-- a wipe needs someone caught: a teammate leaving never rolls the team back
	if anyDowned and (solo or not anyStanding) then
		wipePending = true
		local delaySec = if solo then Config.DOWNED.soloRestoreDelay else Config.DOWNED.wipeRestoreDelay
		GameState.fx("TeamCaught", { solo = solo, delay = delaySec })
		task.delay(delaySec, function()
			wipePending = false
			-- re-check: someone may have joined or been revived meanwhile
			local downedNow = false
			for _, p in GameState.activePlayers() do
				if PlayerStatus.isDowned(p) then
					downedNow = true
				end
			end
			local still = downedNow and (#PlayerStatus.standing() == 0 or #Players:GetPlayers() <= 1)
			if still then
				PlayerStatus.TeamWiped:Fire(if solo then "caught" else "everyone caught")
			end
		end)
	end
end

function PlayerStatus.revive(p: Player, by: Player?)
	if not PlayerStatus.isDowned(p) then
		return
	end
	p:SetAttribute("Downed", false)
	p:SetAttribute("Grace", os.clock() + 3)
	setMobility(p, true)
	local prompt = revivePrompts[p]
	if prompt then
		prompt:Destroy()
		revivePrompts[p] = nil
	end
	GameState.fx("Revived", { name = p.DisplayName, by = if by then by.DisplayName else nil })
	GameState.markDirty()
	PlayerStatus.Revived:Fire(p)
end

function PlayerStatus.down(p: Player, cause: string?)
	if PlayerStatus.isDowned(p) or p:GetAttribute("Escaped") == true then
		return
	end
	local grace = p:GetAttribute("Grace")
	if typeof(grace) == "number" and os.clock() < grace then
		return
	end
	local root = Guard.rootOf(p)
	if not root then
		return
	end
	p:SetAttribute("Downed", true)
	Workstation.kick(p, "caught")
	Drives.recoverFor(p, p.DisplayName .. " was caught")
	setMobility(p, false)
	local prompt = Prompts.make(root, {
		action = "Help up",
		object = p.DisplayName,
		hold = Config.DOWNED.reviveHold,
		distance = Config.REACH.revive,
	})
	prompt:SetAttribute("OwnerUserId", p.UserId)
	revivePrompts[p] = prompt
	prompt.Triggered:Connect(function(helper)
		if helper == p or not Prompts.valid(helper, prompt, "revive") then
			return
		end
		PlayerStatus.revive(p, helper)
	end)
	GameState.fx("Downed", { name = p.DisplayName, cause = cause })
	GameState.notify(nil, p.DisplayName .. " was caught" .. (if cause then " (" .. cause .. ")" else "") .. ". Help them up!", "bad")
	GameState.markDirty()
	PlayerStatus.Downed:Fire(p)
	checkWipe()
end

function PlayerStatus.reviveAll()
	for _, p in Players:GetPlayers() do
		PlayerStatus.revive(p, nil)
	end
end

function PlayerStatus.setEscaped(p: Player, v: boolean)
	p:SetAttribute("Escaped", v)
	GameState.markDirty()
end

function PlayerStatus.respawnAll()
	for _, p in Players:GetPlayers() do
		p:SetAttribute("Downed", false)
		p:SetAttribute("Escaped", false)
		p:SetAttribute("ClockedOut", false)
		p:SetAttribute("Carrying", nil)
		local prompt = revivePrompts[p]
		if prompt then
			prompt:Destroy()
			revivePrompts[p] = nil
		end
		task.spawn(function()
			p:LoadCharacter()
		end)
	end
end

local function onCharacter(p: Player, character: Model)
	p:SetAttribute("Downed", false)
	p:SetAttribute("Carrying", nil)
	revivePrompts[p] = nil
	local h = character:WaitForChild("Humanoid", 10)
	if h and h:IsA("Humanoid") then
		h.WalkSpeed = 16
		h.UseJumpPower = false
		h.JumpHeight = 7.2
		h.Died:Connect(function()
			Drives.recoverFor(p, "carrier lost")
		end)
	end
end

function PlayerStatus.init()
	local function hook(p: Player)
		p.CharacterAdded:Connect(function(c)
			onCharacter(p, c)
		end)
		if p.Character then
			onCharacter(p, p.Character)
		end
	end
	Players.PlayerAdded:Connect(hook)
	for _, p in Players:GetPlayers() do
		hook(p)
	end
	Players.PlayerRemoving:Connect(function(p)
		revivePrompts[p] = nil
		-- the remaining team may now be entirely downed
		task.defer(checkWipe)
	end)
end

return PlayerStatus
