--!strict
-- Server-side validation helpers shared by every remote/prompt handler:
-- token-bucket rate limits, reach checks and argument type guards.

local Players = game:GetService("Players")

local Guard = {}

type Bucket = { tokens: number, last: number }
local buckets: { [Player]: { [string]: Bucket } } = {}

function Guard.allow(player: Player, key: string, ratePerSec: number, burst: number): boolean
	local now = os.clock()
	local pb = buckets[player]
	if not pb then
		pb = {}
		buckets[player] = pb
	end
	local b = pb[key]
	if not b then
		b = { tokens = burst, last = now }
		pb[key] = b
	end
	b.tokens = math.min(burst, b.tokens + (now - b.last) * ratePerSec)
	b.last = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

function Guard.rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

function Guard.humanoidOf(player: Player): Humanoid?
	local character = player.Character
	local h = character and character:FindFirstChildOfClass("Humanoid")
	if h and h.Health > 0 then
		return h
	end
	return nil
end

function Guard.alive(player: Player): boolean
	return player.Parent ~= nil and Guard.humanoidOf(player) ~= nil
end

function Guard.near(player: Player, position: Vector3, maxDistance: number): boolean
	local root = Guard.rootOf(player)
	if not root then
		return false
	end
	return (root.Position - position).Magnitude <= maxDistance
end

-- finite integer in [lo, hi]
function Guard.int(v: unknown, lo: number, hi: number): number?
	if typeof(v) ~= "number" then
		return nil
	end
	if v ~= v or v ~= math.floor(v) or v < lo or v > hi then
		return nil
	end
	return v
end

function Guard.str(v: unknown, maxLen: number): string?
	if typeof(v) ~= "string" or #v > maxLen then
		return nil
	end
	return v
end

function Guard.forget(key: any)
	buckets[key] = nil
end

Players.PlayerRemoving:Connect(function(player)
	buckets[player] = nil
end)

return Guard
