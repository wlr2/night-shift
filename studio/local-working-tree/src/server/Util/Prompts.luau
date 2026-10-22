--!strict
-- ProximityPrompt factory + server-side trigger validation. Prompts already
-- enforce distance on the client; the server re-checks everything because
-- prompt triggers can be spoofed like any other remote.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Guard = require(script.Parent.Guard)

local Prompts = {}

-- server-side record of when each player began holding each prompt, so an
-- exploit that fires Triggered instantly cannot skip a hold
local holdStart: { [ProximityPrompt]: { [Player]: number } } = {}

export type PromptOpts = {
	action: string,
	object: string?,
	hold: number?,
	distance: number?,
	key: Enum.KeyCode?,
	gamepad: Enum.KeyCode?,
	offset: Vector2?,
	sight: boolean?,
	style: string?,
}

function Prompts.make(parent: Instance, opts: PromptOpts): ProximityPrompt
	local p = Instance.new("ProximityPrompt")
	p.ActionText = opts.action
	p.ObjectText = opts.object or ""
	p.HoldDuration = opts.hold or 0
	p.MaxActivationDistance = opts.distance or Config.REACH.prompt
	p.KeyboardKeyCode = opts.key or Enum.KeyCode.E
	p.GamepadKeyCode = opts.gamepad or Enum.KeyCode.ButtonX
	p.RequiresLineOfSight = opts.sight == true
	p.UIOffset = opts.offset or Vector2.zero
	p.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	if opts.style then
		p:SetAttribute("Style", opts.style)
	end
	local starts: { [Player]: number } = {}
	holdStart[p] = starts
	p.PromptButtonHoldBegan:Connect(function(player)
		starts[player] = os.clock()
	end)
	p.Destroying:Connect(function()
		holdStart[p] = nil
	end)
	p.Parent = parent
	return p
end

local function promptPosition(prompt: ProximityPrompt): Vector3?
	local parent = prompt.Parent
	if parent and parent:IsA("BasePart") then
		return parent.Position
	elseif parent and parent:IsA("Attachment") then
		return parent.WorldPosition
	elseif parent and parent:IsA("Model") then
		return parent:GetPivot().Position
	end
	return nil
end

-- True when this trigger is plausible: player alive, not downed/escaped,
-- prompt enabled and within reach (+ latency tolerance).
function Prompts.valid(player: Player, prompt: ProximityPrompt, rateKey: string?): boolean
	if not prompt.Enabled then
		return false
	end
	if player:GetAttribute("Downed") == true or player:GetAttribute("Escaped") == true then
		return false
	end
	if not Guard.alive(player) then
		return false
	end
	if not Guard.allow(player, rateKey or "prompt", 4, 6) then
		return false
	end
	if prompt.HoldDuration > 0 then
		local starts = holdStart[prompt]
		local began = starts and starts[player]
		if starts then
			starts[player] = nil
		end
		if not began or os.clock() - began < prompt.HoldDuration - 0.2 then
			return false
		end
	end
	local pos = promptPosition(prompt)
	if not pos then
		return false
	end
	return Guard.near(player, pos, prompt.MaxActivationDistance + Config.REACH.tolerance)
end

game:GetService("Players").PlayerRemoving:Connect(function(player)
	for _, starts in holdStart do
		starts[player] = nil
	end
end)

return Prompts
