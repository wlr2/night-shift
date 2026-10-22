return function()
-- Dev-only: pull changed sources from `python -m http.server 34999` (run in
-- the night-shift folder after `python tools/devsync.py`) into the open place.
-- Paste into the Studio command bar (Edit mode). Requires HttpService.HttpEnabled.
local HttpService = game:GetService("HttpService")
HttpService.HttpEnabled = true
local BASE = "http://127.0.0.1:34999"
local manifest = HttpService:JSONDecode(HttpService:GetAsync(BASE .. "/build/manifest.json", true))
local function resolve(path, leafClass)
	local segs = string.split(path, ".")
	local node = game:GetService(segs[1])
	for i = 2, #segs do
		local name = segs[i]
		local child = node:FindFirstChild(name)
		local want = if i == #segs then leafClass else nil
		if child and want and child.ClassName ~= want then
			local replacement = Instance.new(want)
			replacement.Name = name
			for _, c in child:GetChildren() do c.Parent = replacement end
			child:Destroy()
			replacement.Parent = node
			child = replacement
		end
		if not child then
			child = Instance.new(want or "Folder")
			child.Name = name
			child.Parent = node
		end
		node = child
	end
	return node
end
local wanted = {}
local changed = 0
for _, e in manifest do
	wanted[e.path] = true
	local inst = resolve(e.path, e.class)
	if inst:GetAttribute("SyncHash") ~= e.hash then
		inst.Source = HttpService:GetAsync(BASE .. e.url, true)
		inst:SetAttribute("SyncHash", e.hash)
		changed += 1
	end
end
local removed = 0
for _, root in { game.ReplicatedStorage.Shared, game.ReplicatedStorage.ArtData, game.ServerScriptService.Server, game.StarterPlayer.StarterPlayerScripts.Client } do
	for _, d in root:GetDescendants() do
		if d:IsA("LuaSourceContainer") and not wanted[d:GetFullName()] then
			d:Destroy()
			removed += 1
		end
	end
end
for _, n in { "Gallery", "BakedArt", "Map" } do
	local x = workspace:FindFirstChild(n)
	if x then x:Destroy() end
end
workspace:SetAttribute("MapReady", nil)
return string.format("synced %d changed, %d removed, %d total", changed, removed, #manifest)

end