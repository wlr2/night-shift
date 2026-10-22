--!strict
-- NIGHT SHIFT: DATA PURGE — client entry point. Presentation, input,
-- camera and cosmetic effects only; the server owns all game state.

local Controllers = script:WaitForChild("Controllers")

local ORDER = {
	"State",
	"ArtController",
	"Atmosphere",
	"Hud",
	"Desktop",
	"WorkstationCamera",
	"Effects",
	"Pings",
}

local loaded: { any } = {}
local seen: { [string]: boolean } = {}
for _, name in ORDER do
	local m = Controllers:FindFirstChild(name)
	if m and m:IsA("ModuleScript") then
		table.insert(loaded, (require :: any)(m))
		seen[name] = true
	end
end
for _, child in Controllers:GetChildren() do
	if child:IsA("ModuleScript") and not seen[child.Name] then
		table.insert(loaded, (require :: any)(child))
	end
end

for _, controller in loaded do
	if typeof(controller.init) == "function" then
		controller.init()
	end
end
for _, controller in loaded do
	if typeof(controller.start) == "function" then
		task.spawn(controller.start)
	end
end

print("[NightShift] client started")
