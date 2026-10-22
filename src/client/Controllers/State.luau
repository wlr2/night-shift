--!strict
-- Client mirror of server state. Pure presentation input: the client never
-- decides anything from this, it only renders it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Types = require(ReplicatedStorage.Shared.Types)

local State = {}

State.snapshot = nil :: Types.Snapshot?
State.session = nil :: Types.SessionPayload?
State.Changed = Signal.new() :: Signal.Signal<Types.Snapshot>
State.SessionChanged = Signal.new() :: Signal.Signal<Types.SessionPayload>
State.Notified = Signal.new() :: Signal.Signal<string, string>
State.Fx = Signal.new() :: Signal.Signal<string, any>
State.Pinged = Signal.new() :: Signal.Signal<Vector3, string, string>

function State.init()
	Net.remote("State").OnClientEvent:Connect(function(snap: Types.Snapshot)
		State.snapshot = snap
		State.Changed:Fire(snap)
	end)
	Net.remote("Session").OnClientEvent:Connect(function(payload: Types.SessionPayload)
		State.session = payload
		State.SessionChanged:Fire(payload)
	end)
	Net.remote("Notify").OnClientEvent:Connect(function(text: string, kind: string)
		State.Notified:Fire(text, kind)
	end)
	Net.remote("Fx").OnClientEvent:Connect(function(name: string, data: any)
		State.Fx:Fire(name, data)
	end)
	Net.remote("Ping").OnClientEvent:Connect(function(pos: Vector3, by: string, where: string)
		State.Pinged:Fire(pos, by, where)
	end)
end

function State.nightClock(minutes: number?): string
	local m = math.floor(minutes or (if State.snapshot then State.snapshot.nightMinutes else 0))
	local h = (m // 60) % 24
	local suffix = if h >= 12 then "PM" else "AM"
	local h12 = h % 12
	if h12 == 0 then
		h12 = 12
	end
	return string.format("%d:%02d %s", h12, m % 60, suffix)
end

return State
