--!strict
-- Sound helper. Sound IDs live in Config.SOUNDS (empty = silent). Positional
-- sounds are parented to a temporary attachment so 3D falloff applies.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Config = require(ReplicatedStorage.Shared.Config)

local Sfx = {}

local anchor: Part? = nil
local function getAnchor(): Part
	if anchor and anchor.Parent then
		return anchor
	end
	local p = Instance.new("Part")
	p.Name = "SfxAnchor"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.new(0.2, 0.2, 0.2)
	p.CFrame = CFrame.new(0, -100, 0)
	p.Parent = workspace
	anchor = p
	return p
end

export type PlayOpts = { volume: number?, speed: number?, pos: Vector3?, looped: boolean?, duration: number? }

function Sfx.id(name: string): string
	local v = (Config.SOUNDS :: any)[name]
	return if typeof(v) == "string" then v else ""
end

function Sfx.play(name: string, opts: PlayOpts?): Sound?
	local id = Sfx.id(name)
	if id == "" then
		return nil
	end
	local o: PlayOpts = opts or {}
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = o.volume or 0.5
	s.PlaybackSpeed = (o.speed or 1) * (0.95 + math.random() * 0.1)
	s.Looped = o.looped == true
	s.RollOffMaxDistance = 80
	s.RollOffMinDistance = 6
	if o.pos then
		local att = Instance.new("Attachment")
		att.WorldPosition = o.pos
		att.Parent = getAnchor()
		att.WorldPosition = o.pos
		s.Parent = att
		s.Ended:Connect(function()
			att:Destroy()
		end)
		if o.duration then
			task.delay(o.duration, function()
				att:Destroy()
			end)
		end
	else
		s.Parent = SoundService
		s.Ended:Connect(function()
			s:Destroy()
		end)
		if o.duration then
			task.delay(o.duration, function()
				s:Destroy()
			end)
		end
	end
	s:Play()
	return s
end

return Sfx
