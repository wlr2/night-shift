--!strict
-- Turns the converted low-poly library (ReplicatedStorage.ArtData) into real
-- meshes on this client with EditableMesh / EditableImage.
--
-- Roblox clients may hold only a handful of EditableMeshes (8 in Studio
-- tests, 60k vertices / 20k triangles each), so every STATIC prop is baked
-- into a few merged world-space chunks that share one texture atlas. Only
-- moving props (the figure outside, crew silhouettes) get their own mesh.
--
-- The server places invisible parts tagged "ArtAnchor" with an ArtKey
-- attribute and flips workspace "MapReady" when the map is complete.
-- Visual only: collision always comes from server-side proxy parts.

local AssetService = game:GetService("AssetService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Base64 = require(ReplicatedStorage.Shared.Util.Base64)

local ArtData = ReplicatedStorage:WaitForChild("ArtData")
local Index = require(ArtData:WaitForChild("Index")) :: any
local ModelsFolder = ArtData:WaitForChild("Models")
local TexturesFolder = ArtData:WaitForChild("Textures")

type PartData = {
	nv: number,
	nt: number,
	color: { number },
	center: { number },
	size: { number },
	v: string,
	n: string,
	uv: string,
	i: string,
}

type ModelData = { parts: { PartData }, min: { number }, max: { number } }

type Chunk = {
	em: EditableMesh,
	verts: number,
	tris: number,
	colors: { [string]: number },
}

local MAX_VERTS = 59000
local MAX_TRIS = 19900
local MAX_MESHES = 8

local ArtController = {}

local modelCache: { [string]: ModelData | false } = {}
local surfaceCache: { [string]: EditableImage | false } = {}
local atlas: EditableImage? = nil
local meshesUsed = 0
local baked = false
local dynamicBuilt: { [BasePart]: MeshPart } = {}

ArtController.stats = { chunks = 0, staticProps = 0, dynamicProps = 0, triangles = 0, skipped = 0 }

local function decode565(data: { w: number, h: number, data: string }, dest: buffer, destWidth: number, rowOffset: number)
	local raw = Base64.decode(data.data)
	for y = 0, data.h - 1 do
		for x = 0, data.w - 1 do
			local v = buffer.readu16(raw, (y * data.w + x) * 2)
			local o = ((y + rowOffset) * destWidth + x) * 4
			buffer.writeu8(dest, o, bit32.rshift(v, 11) * 255 // 31)
			buffer.writeu8(dest, o + 1, bit32.band(bit32.rshift(v, 5), 63) * 255 // 63)
			buffer.writeu8(dest, o + 2, bit32.band(v, 31) * 255 // 31)
			buffer.writeu8(dest, o + 3, 255)
		end
	end
end

local function loadAtlas(): EditableImage?
	if atlas then
		return atlas
	end
	local info = Index.atlas
	local px = buffer.create(info.w * info.h * 4)
	for i = 0, info.strips - 1 do
		local mod = TexturesFolder:FindFirstChild("Atlas_" .. i)
		if mod and mod:IsA("ModuleScript") then
			decode565((require :: any)(mod), px, info.w, i * info.strip)
		end
		if i % 2 == 1 then
			task.wait()
		end
	end
	local ok, img = pcall(function()
		local image = AssetService:CreateEditableImage({ Size = Vector2.new(info.w, info.h) })
		image:WritePixelsBuffer(Vector2.zero, Vector2.new(info.w, info.h), px)
		return image
	end)
	if ok then
		atlas = img
		return img
	end
	warn("[Art] atlas failed", img)
	return nil
end

-- Surface textures (walls, floors, paper) for server-built parts, applied
-- through Texture.ColorMapContent.
function ArtController.getSurface(name: string): EditableImage?
	local cached = surfaceCache[name]
	if cached == false then
		return nil
	elseif cached ~= nil then
		return cached :: EditableImage
	end
	local key = Index.surfaces[name]
	local mod = key and TexturesFolder:FindFirstChild(key)
	if not mod or not mod:IsA("ModuleScript") then
		surfaceCache[name] = false
		return nil
	end
	local data = (require :: any)(mod) :: { w: number, h: number, data: string }
	local px = buffer.create(data.w * data.h * 4)
	decode565(data, px, data.w, 0)
	local ok, img = pcall(function()
		local image = AssetService:CreateEditableImage({ Size = Vector2.new(data.w, data.h) })
		image:WritePixelsBuffer(Vector2.zero, Vector2.new(data.w, data.h), px)
		return image
	end)
	local result = if ok then img :: EditableImage else nil
	surfaceCache[name] = result or false
	return result
end

local function getModel(key: string): ModelData?
	local cached = modelCache[key]
	if cached == false then
		return nil
	elseif cached ~= nil then
		return cached :: ModelData
	end
	local mod = ModelsFolder:FindFirstChild(key)
	if not mod or not mod:IsA("ModuleScript") then
		modelCache[key] = false
		return nil
	end
	local ok, data = pcall(function()
		return (require :: any)(mod) :: ModelData
	end)
	local result = if ok then data :: ModelData else nil
	modelCache[key] = result or false
	return result
end

local function newChunk(): Chunk?
	if meshesUsed >= MAX_MESHES then
		return nil
	end
	local em = AssetService:CreateEditableMesh()
	if not em then
		return nil
	end
	meshesUsed += 1
	return { em = em, verts = 0, tris = 0, colors = {} }
end

local function finalizeChunk(chunk: Chunk, name: string, parent: Instance): MeshPart?
	if chunk.tris == 0 then
		return nil
	end
	local ok, mp = pcall(function()
		return AssetService:CreateMeshPartAsync(Content.fromObject(chunk.em), {
			CollisionFidelity = Enum.CollisionFidelity.Box,
		})
	end)
	if not ok or not mp then
		warn("[Art] chunk failed", mp)
		return nil
	end
	mp.Name = name
	mp.Anchored = true
	mp.CanCollide = false
	mp.CanQuery = false
	mp.CanTouch = false
	mp.Material = Enum.Material.SmoothPlastic
	mp.Color = Color3.new(1, 1, 1)
	local img = loadAtlas()
	if img then
		mp.TextureContent = Content.fromObject(img)
	end
	mp.CFrame = CFrame.identity
	mp.Parent = parent
	ArtController.stats.triangles += chunk.tris
	return mp
end

-- Appends one model instance (transformed by cf, uniform scale s) to chunk.
local function appendModel(chunk: Chunk, data: ModelData, cf: CFrame, s: number, tint: Color3?)
	local em = chunk.em
	for _, pd in data.parts do
		local vb = Base64.decode(pd.v)
		local nb = Base64.decode(pd.n)
		local ub = Base64.decode(pd.uv)
		local ib = Base64.decode(pd.i)
		local cx, cy, cz = pd.center[1], pd.center[2], pd.center[3]
		local hx, hy, hz = pd.size[1] / 2, pd.size[2] / 2, pd.size[3] / 2
		local r, g, b = pd.color[1], pd.color[2], pd.color[3]
		if tint then
			r, g, b = r * tint.R, g * tint.G, b * tint.B
		end
		local ckey = string.format("%.3f,%.3f,%.3f", r, g, b)
		local colorId = chunk.colors[ckey]
		if not colorId then
			colorId = em:AddColor(Color3.new(r, g, b), 1)
			chunk.colors[ckey] = colorId
		end
		local vids = table.create(pd.nv)
		local nids = table.create(pd.nv)
		local uids = table.create(pd.nv)
		for k = 0, pd.nv - 1 do
			local lx = (cx + buffer.readi16(vb, k * 6) / 32767 * hx) * s
			local ly = (cy + buffer.readi16(vb, k * 6 + 2) / 32767 * hy) * s
			local lz = (cz + buffer.readi16(vb, k * 6 + 4) / 32767 * hz) * s
			vids[k + 1] = em:AddVertex(cf:PointToWorldSpace(Vector3.new(lx, ly, lz)))
			local n = Vector3.new(buffer.readi8(nb, k * 3), buffer.readi8(nb, k * 3 + 1), buffer.readi8(nb, k * 3 + 2)) / 127
			nids[k + 1] = em:AddNormal(cf:VectorToWorldSpace(n))
			uids[k + 1] = em:AddUV(Vector2.new(buffer.readu16(ub, k * 4) / 65535, buffer.readu16(ub, k * 4 + 2) / 65535))
		end
		local colors = { colorId, colorId, colorId }
		for t = 0, pd.nt - 1 do
			local a = buffer.readu16(ib, t * 6) + 1
			local bb = buffer.readu16(ib, t * 6 + 2) + 1
			local c = buffer.readu16(ib, t * 6 + 4) + 1
			local ok, fid = pcall(em.AddTriangle, em, vids[a], vids[bb], vids[c])
			if ok then
				em:SetFaceNormals(fid, { nids[a], nids[bb], nids[c] })
				em:SetFaceUVs(fid, { uids[a], uids[bb], uids[c] })
				em:SetFaceColors(fid, colors)
				chunk.tris += 1
			end
		end
		chunk.verts += pd.nv
	end
end

local function modelCounts(data: ModelData): (number, number)
	local v, t = 0, 0
	for _, pd in data.parts do
		v += pd.nv
		t += pd.nt
	end
	return v, t
end

local function anchorParams(anchor: BasePart): (string?, number, Color3?)
	local key = anchor:GetAttribute("ArtKey")
	local scale = anchor:GetAttribute("ArtScale")
	local tint = anchor:GetAttribute("ArtTint")
	return (if typeof(key) == "string" then key else nil),
		(if typeof(scale) == "number" then scale else 1),
		(if typeof(tint) == "Color3" then tint else nil)
end

-- Bakes every static anchor into merged chunks. Reserves room for dynamic props.
local function bakeStatic()
	if baked then
		return
	end
	baked = true
	local folder = Instance.new("Folder")
	folder.Name = "BakedArt"
	folder.Parent = workspace
	loadAtlas()

	local anchors: { BasePart } = {}
	for _, inst in CollectionService:GetTagged("ArtAnchor") do
		if inst:IsA("BasePart") and inst:GetAttribute("ArtDynamic") ~= true then
			table.insert(anchors, inst)
		end
	end
	-- spatial ordering keeps chunks compact (better culling)
	table.sort(anchors, function(a, b)
		return a.Position.X < b.Position.X
	end)

	local reserveForDynamic = 3
	local chunk = newChunk()
	local chunkIndex = 1
	local workDone = 0
	for _, anchor in anchors do
		local key, s, tint = anchorParams(anchor)
		local data = key and getModel(key)
		if data and chunk then
			local nv, nt = modelCounts(data)
			if chunk.verts + nv > MAX_VERTS or chunk.tris + nt > MAX_TRIS then
				finalizeChunk(chunk, "Chunk" .. chunkIndex, folder)
				chunkIndex += 1
				chunk = if meshesUsed < MAX_MESHES - reserveForDynamic then newChunk() else nil
			end
			if chunk then
				appendModel(chunk, data, anchor.CFrame, s, tint)
				ArtController.stats.staticProps += 1
				workDone += nv
				if workDone > 2500 then
					workDone = 0
					task.wait()
				end
			else
				ArtController.stats.skipped += 1
			end
		elseif data then
			ArtController.stats.skipped += 1
		end
	end
	if chunk then
		finalizeChunk(chunk, "Chunk" .. chunkIndex, folder)
	end
	ArtController.stats.chunks = chunkIndex
end

local function buildDynamic(anchor: BasePart)
	if dynamicBuilt[anchor] or not anchor.Parent then
		return
	end
	local key, s, tint = anchorParams(anchor)
	local data = key and getModel(key)
	if not data then
		return
	end
	local chunk = newChunk()
	if not chunk then
		warn("[Art] no mesh budget left for", key)
		return
	end
	-- build in the anchor's local space, then weld to it
	appendModel(chunk, data, CFrame.identity, s, tint)
	local mp = finalizeChunk(chunk, key or "Dynamic", anchor)
	if not mp then
		return
	end
	mp.Anchored = false
	mp.Massless = true
	mp.CFrame = anchor.CFrame
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = anchor
	weld.Part1 = mp
	weld.Parent = mp
	dynamicBuilt[anchor] = mp
	ArtController.stats.dynamicProps += 1
	local function syncHidden()
		mp.Transparency = if anchor:GetAttribute("ArtHidden") == true then 1 else 0
	end
	syncHidden()
	anchor:GetAttributeChangedSignal("ArtHidden"):Connect(syncHidden)
end

function ArtController.isReady(): boolean
	return baked
end

function ArtController.init()
	CollectionService:GetInstanceAddedSignal("ArtAnchor"):Connect(function(inst: Instance)
		if baked and inst:IsA("BasePart") and inst:GetAttribute("ArtDynamic") == true then
			task.spawn(buildDynamic, inst)
		end
	end)
end

function ArtController.start()
	while workspace:GetAttribute("MapReady") ~= true do
		task.wait(0.1)
	end
	local ok, err = pcall(bakeStatic :: any)
	if not ok then
		warn("[Art] bake failed", err)
	end
	for _, inst in CollectionService:GetTagged("ArtAnchor") do
		if inst:IsA("BasePart") and inst:GetAttribute("ArtDynamic") == true then
			task.spawn(buildDynamic, inst)
		end
	end
	workspace:SetAttribute("ClientArtReady", true)
end

return ArtController
