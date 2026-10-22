--!strict
-- Simple team pings so voice chat is never required. Validated and
-- rate-limited; the server rebroadcasts to everyone.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Layout = require(ReplicatedStorage.Shared.Layout)
local Net = require(ReplicatedStorage.Shared.Net)
local Server = script.Parent.Parent
local Guard = require(Server.Util.Guard)

local Pings = {}

function Pings.init()
	local remote = Net.remote("Ping")
	remote.OnServerEvent:Connect(function(player, pos: unknown)
		local rate = Config.RATE.ping
		if not Guard.allow(player, "ping", rate[1], rate[2]) then
			return
		end
		if typeof(pos) ~= "Vector3" then
			return
		end
		local v = pos :: Vector3
		if v.X ~= v.X or v.Y ~= v.Y or v.Z ~= v.Z then
			return
		end
		if not Guard.near(player, v, Config.PING.maxDistance) or not Layout.inMap(v) then
			return
		end
		if player:GetAttribute("Escaped") == true then
			return
		end
		remote:FireAllClients(v, player.DisplayName, Layout.regionOf(v))
	end)
end

return Pings
