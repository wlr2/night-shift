--!strict
-- NIGHT SHIFT: DATA PURGE — server entry point.
-- Two-phase bootstrap: every system's init() runs (wiring, remotes, map),
-- then every system's start() runs in its own thread.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)
Net.init()

local Systems = script:WaitForChild("Systems")

-- Explicit order: the map must exist before systems that reference it.
local ORDER = {
	"MapBuilder",
	"GameState",
	"Power",
	"Doors",
	"Drives",
	"Workstation",
	"Threat",
	"PlayerStatus",
	"Checkpoints",
	"Story",
	"Finale",
	"EventDirector",
	"Pings",
	"Cheats",
}

local loaded: { { name: string, mod: any } } = {}
local seen: { [string]: boolean } = {}
for _, name in ORDER do
	local m = Systems:FindFirstChild(name)
	if m and m:IsA("ModuleScript") then
		table.insert(loaded, { name = name, mod = (require :: any)(m) })
		seen[name] = true
	end
end
for _, child in Systems:GetChildren() do
	if child:IsA("ModuleScript") and not seen[child.Name] then
		table.insert(loaded, { name = child.Name, mod = (require :: any)(child) })
	end
end

for _, entry in loaded do
	if typeof(entry.mod.init) == "function" then
		entry.mod.init()
	end
end
for _, entry in loaded do
	if typeof(entry.mod.start) == "function" then
		task.spawn(entry.mod.start)
	end
end

print("[NightShift] server started with", #loaded, "systems")
