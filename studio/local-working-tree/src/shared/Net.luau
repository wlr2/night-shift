--!strict
-- Remote registry. The server creates every remote at startup from this one
-- list; clients only wait for them. Adding a remote is one line here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

export type RemoteName =
	"State" -- S->C full snapshot
	| "Session" -- S->C workstation session payload for the operator
	| "Notify" -- S->C toast { text, kind }
	| "Fx" -- S->C cosmetic cue (name, data)
	| "Desktop" -- C->S (sessionId, kind, a, b)
	| "Leave" -- C->S leave workstation
	| "Ping" -- C->S ping position ; S->C ping broadcast
	| "Cheat" -- C->S studio/dev only

local NAMES: { RemoteName } = { "State", "Session", "Notify", "Fx", "Desktop", "Leave", "Ping", "Cheat" }

local Net = {}

local folder: Folder? = nil

local function getFolder(): Folder
	local cached = folder
	if cached then
		return cached
	end
	if RunService:IsServer() then
		local existing = ReplicatedStorage:FindFirstChild("Remotes")
		if existing and existing:IsA("Folder") then
			folder = existing
		else
			local f = Instance.new("Folder")
			f.Name = "Remotes"
			for _, name in NAMES do
				local r = Instance.new("RemoteEvent")
				r.Name = name
				r.Parent = f
			end
			f.Parent = ReplicatedStorage
			folder = f
		end
	else
		folder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	end
	return folder :: Folder
end

function Net.remote(name: RemoteName): RemoteEvent
	local f = getFolder()
	local r = if RunService:IsServer() then f:FindFirstChild(name) else f:WaitForChild(name)
	assert(r and r:IsA("RemoteEvent"), "missing remote " .. name)
	return r
end

function Net.init()
	getFolder()
end

return Net
