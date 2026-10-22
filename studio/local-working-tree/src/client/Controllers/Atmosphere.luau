--!strict
-- Mood: a restrained night grade, cold pale fog kept outside the glass, rain
-- in the alley and on the windows, a little film grain, ambient loops, a
-- personal dim light for blackouts, the blinking door indicator and a gradual
-- "dread" shift as more data is erased. Everything here is cosmetic and
-- client-local.
--
-- Palette: outdoor fog #A8BAC3, cold ambient #778B96, shadowed walls #353F46,
-- carpet/curtains #60494D, cream trim #B7B09C, amber practicals #C8A66B.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local AssetService = game:GetService("AssetService")

local Layout = require(ReplicatedStorage.Shared.Layout)
local ArtController = require(script.Parent.ArtController)
local State = require(script.Parent.State)
local Sfx = require(script.Parent.Parent.Ui.Sfx)

local player = Players.LocalPlayer

local Atmosphere = {}

local SILKSCREEN = "rbxassetid://12187371840"
local TINT_WARM = Color3.fromRGB(250, 246, 238)
local TINT_COLD = Color3.fromRGB(214, 226, 240)
local FOG = Color3.fromRGB(168, 186, 195)
local FOG_DECAY = Color3.fromRGB(96, 110, 120)

local cc: ColorCorrectionEffect
local bloom: BloomEffect
local atmos: Atmosphere
local rainEmitters: { ParticleEmitter } = {}
local grain: ImageLabel? = nil
local grainImages: { EditableImage } = {}
local dread = 0
local flashOverride: number? = nil

Atmosphere.cc = function(): ColorCorrectionEffect
	return cc
end

-- Surface textures are near-neutral; these tints set the final albedo.
local function applySurfaces()
	local tints: { [string]: Color3 } = {
		carpet = Color3.fromRGB(226, 198, 202), -- dusty burgundy
		ceiling_tile = Color3.fromRGB(214, 212, 204),
		wall_office = Color3.fromRGB(226, 220, 206),
		wall_kitchen = Color3.fromRGB(212, 216, 210),
		wall_concrete = Color3.fromRGB(190, 196, 200),
		floor_tile = Color3.fromRGB(205, 206, 202),
		floor_lobby = Color3.fromRGB(206, 200, 190),
		floor_concrete = Color3.fromRGB(190, 194, 192),
		brick_alley = Color3.fromRGB(196, 206, 212),
	}
	local function apply(t: Instance)
		if not t:IsA("Texture") then
			return
		end
		local name = t:GetAttribute("Surface")
		if typeof(name) ~= "string" then
			return
		end
		local img = ArtController.getSurface(name)
		if img then
			t.ColorMapContent = Content.fromObject(img)
			local tint = tints[name]
			if tint then
				t.Color3 = tint
			end
		end
	end
	for _, t in CollectionService:GetTagged("Surface") do
		apply(t)
	end
	CollectionService:GetInstanceAddedSignal("Surface"):Connect(apply)
end

local function makeRain(region: { minX: number, maxX: number, minZ: number, maxZ: number }, height: number): ParticleEmitter
	local p = Instance.new("Part")
	p.Name = "RainCloud"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.new(region.maxX - region.minX, 1, region.maxZ - region.minZ)
	p.Position = Vector3.new((region.minX + region.maxX) / 2, height, (region.minZ + region.maxZ) / 2)
	p.Parent = workspace
	local e = Instance.new("ParticleEmitter")
	e.Rate = 240
	e.Lifetime = NumberRange.new(0.9, 1.1)
	e.Speed = NumberRange.new(55, 65)
	e.EmissionDirection = Enum.NormalId.Bottom
	e.SpreadAngle = Vector2.new(4, 4)
	e.Size = NumberSequence.new(0.06)
	e.Squash = NumberSequence.new(-3.5)
	e.Transparency = NumberSequence.new(0.6)
	e.LightEmission = 0.1
	e.LightInfluence = 0.7
	e.Color = ColorSequence.new(FOG)
	e.Orientation = Enum.ParticleOrientation.FacingCameraWorldUp
	e.Parent = p
	table.insert(rainEmitters, e)
	return e
end

local function rainOnGlass()
	-- slow drips sliding down each window (client-only frames)
	local drips: { { f: Frame, speed: number } } = {}
	for _, part in workspace:GetDescendants() do
		if part:IsA("BasePart") and part:GetAttribute("RainGlass") == true then
			local sg = Instance.new("SurfaceGui")
			sg.Face = Enum.NormalId.Back
			sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
			sg.PixelsPerStud = 30
			sg.LightInfluence = 1
			sg.Parent = part
			for _ = 1, 14 do
				local f = Instance.new("Frame")
				f.BorderSizePixel = 0
				f.BackgroundColor3 = Color3.fromRGB(190, 205, 220)
				f.BackgroundTransparency = 0.6 + math.random() * 0.3
				f.Size = UDim2.fromOffset(2, math.random(6, 18))
				f.Position = UDim2.fromScale(math.random(), math.random())
				f.Parent = sg
				table.insert(drips, { f = f, speed = 0.03 + math.random() * 0.08 })
			end
		end
	end
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.1 then
			return
		end
		for _, d in drips do
			local p = d.f.Position
			local y = p.Y.Scale + d.speed * acc
			if y > 1.05 then
				y = -0.05
			end
			d.f.Position = UDim2.fromScale(p.X.Scale, y)
		end
		acc = 0
	end)
end

local function buildGrain()
	local gui = Instance.new("ScreenGui")
	gui.Name = "Grain"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 15
	gui.Parent = player:WaitForChild("PlayerGui")
	local ok = pcall(function()
		for _ = 1, 3 do
			local img = AssetService:CreateEditableImage({ Size = Vector2.new(96, 96) })
			local buf = buffer.create(96 * 96 * 4)
			for i = 0, 96 * 96 - 1 do
				local v = math.random(0, 255)
				buffer.writeu8(buf, i * 4, v)
				buffer.writeu8(buf, i * 4 + 1, v)
				buffer.writeu8(buf, i * 4 + 2, v)
				buffer.writeu8(buf, i * 4 + 3, 255)
			end
			img:WritePixelsBuffer(Vector2.zero, Vector2.new(96, 96), buf)
			table.insert(grainImages, img)
		end
	end)
	if not ok or #grainImages == 0 then
		return
	end
	local label = Instance.new("ImageLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.ImageContent = Content.fromObject(grainImages[1])
	label.ScaleType = Enum.ScaleType.Tile
	label.TileSize = UDim2.fromOffset(192, 192)
	label.ImageTransparency = 0.96
	label.Active = false
	label.Interactable = false
	label.Parent = gui
	grain = label
	local i = 1
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc > 0.06 then
			acc = 0
			i = i % #grainImages + 1
			label.ImageContent = Content.fromObject(grainImages[i])
			label.Position = UDim2.fromOffset(math.random(-40, 0), math.random(-40, 0))
			label.ImageTransparency = 0.96 - dread * 0.02
		end
	end)
end

local function setupLighting()
	cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "NightGrade"
	cc.Saturation = -0.18
	cc.Contrast = 0.06
	cc.Brightness = 0
	cc.TintColor = TINT_WARM
	cc.Parent = Lighting
	bloom = Instance.new("BloomEffect")
	bloom.Name = "SoftBloom"
	bloom.Intensity = 0.25
	bloom.Size = 24
	bloom.Threshold = 2
	bloom.Parent = Lighting
	for _, e in Lighting:GetChildren() do
		if e:IsA("SunRaysEffect") or e:IsA("DepthOfFieldEffect") then
			e.Enabled = false
		end
	end
	-- distance fog: pale blue-grey, thin enough that the 44-stud office stays
	-- clear while the street and alley fade out
	local existing = Lighting:FindFirstChildOfClass("Atmosphere")
	atmos = existing or Instance.new("Atmosphere")
	atmos.Density = 0.22
	atmos.Offset = 0
	atmos.Color = FOG
	atmos.Decay = FOG_DECAY
	atmos.Glare = 0
	atmos.Haze = 1.0
	atmos.Parent = Lighting
	Lighting.ClockTime = 1.5
	Lighting.Brightness = 0.25
	Lighting.Ambient = Color3.fromRGB(46, 54, 60) -- charcoal-blue shadow floor (#353F46 minus a step)
	Lighting.OutdoorAmbient = Color3.fromRGB(108, 124, 134) -- cold slate outside the windows (#778B96)
	Lighting.EnvironmentDiffuseScale = 0.2
	Lighting.EnvironmentSpecularScale = 0.2
	Lighting.ExposureCompensation = 0
end

local function updateDread()
	local v = workspace:GetAttribute("Dread")
	dread = if typeof(v) == "number" then v else 0
	-- colder and greyer as the purge nears; rain picks up
	cc.Saturation = -0.18 - dread * 0.22
	cc.TintColor = TINT_WARM:Lerp(TINT_COLD, dread)
	atmos.Density = 0.22 + dread * 0.12
	for _, e in rainEmitters do
		e.Rate = 220 + dread * 260
	end
end

-- brief brightness dips used by power warnings and flickers (never touches
-- server-owned light state, so nothing can get stuck)
function Atmosphere.flicker(seconds: number, strength: number?)
	local s = strength or 0.35
	local token = os.clock()
	flashOverride = token
	task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < seconds and flashOverride == token do
			cc.Brightness = if math.random() < 0.5 then -s else 0
			task.wait(0.04 + math.random() * 0.12)
		end
		if flashOverride == token then
			cc.Brightness = 0
			flashOverride = nil
		end
	end)
end

local function ambience()
	Sfx.play("ambientRoom", { looped = true, volume = 0.3 })
	Sfx.play("rain", { looped = true, volume = 0.22 })
	Sfx.play("fanHum", { looped = true, volume = 0.12 })
	local tense = Sfx.play("ambientTense", { looped = true, volume = 0 })
	local finale = Sfx.play("ambientFinale", { looped = true, volume = 0 })
	if finale then
		State.Changed:Connect(function(snap)
			local on = snap.phase == "FinalPurge" or snap.phase == "SignOff" or snap.phase == "ClockOut"
			finale.Volume = if on then 0.45 else 0
		end)
	end
	if tense then
		workspace:GetAttributeChangedSignal("Dread"):Connect(function()
			tense.Volume = 0.05 + dread * 0.3
		end)
	end
end

local function personalLight(character: Model)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if root and root:IsA("BasePart") then
		local l = Instance.new("PointLight")
		l.Name = "PhoneGlow"
		l.Range = 9
		l.Brightness = 0.22
		l.Color = Color3.fromRGB(190, 205, 220)
		l.Shadows = false
		l.Parent = root
	end
end

local function doorBlink()
	local acc = 0
	local on = true
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.4 then
			return
		end
		acc = 0
		local map = workspace:FindFirstChild("Map")
		local inter = map and map:FindFirstChild("Interactive")
		local light = inter and inter:FindFirstChild("DoorStatusLight")
		if light and light:IsA("BasePart") then
			on = not on
			light.Transparency = if light:GetAttribute("Alert") == true and not on then 0.8 else 0
		end
	end)
end

local function screenTexts()
	-- source monitor messages set by the story (server attribute "Text")
	local map = workspace:WaitForChild("Map", 20)
	local inter = map and map:WaitForChild("Interactive", 10)
	if not inter then
		return
	end
	for i = 1, 6 do
		local screen = inter:FindFirstChild("SourceScreen_" .. i)
		if screen and screen:IsA("BasePart") then
			local sg = Instance.new("SurfaceGui")
			sg.Name = "StoryText"
			sg.Face = Enum.NormalId.Back
			sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
			sg.PixelsPerStud = 80
			sg.LightInfluence = 0
			sg.Parent = screen
			local t = Instance.new("TextLabel")
			t.Size = UDim2.fromScale(1, 1)
			t.BackgroundTransparency = 1
			t.TextColor3 = Color3.fromRGB(120, 255, 140)
			t.FontFace = Font.new(SILKSCREEN)
			t.TextScaled = true
			t.Text = ""
			t.Parent = sg
			local function sync()
				local v = screen:GetAttribute("Text")
				t.Text = if typeof(v) == "string" then v else ""
				screen.Material = if t.Text ~= "" then Enum.Material.Neon else Enum.Material.SmoothPlastic
				screen.Color = if t.Text ~= "" then Color3.fromRGB(10, 30, 14) else Color3.fromRGB(10, 14, 12)
			end
			screen:GetAttributeChangedSignal("Text"):Connect(sync)
			sync()
		end
	end
end

function Atmosphere.init()
	setupLighting()
end

function Atmosphere.start()
	while workspace:GetAttribute("MapReady") ~= true do
		task.wait(0.1)
	end
	applySurfaces()
	makeRain(Layout.ALLEY, 40)
	makeRain({ minX = -34, maxX = 36, minZ = -29, maxZ = -15 }, 40)
	makeRain(Layout.STREET, 40)
	rainOnGlass()
	buildGrain()
	doorBlink()
	ambience()
	task.spawn(screenTexts)
	workspace:GetAttributeChangedSignal("Dread"):Connect(updateDread)
	updateDread()
	player.CharacterAdded:Connect(personalLight)
	if player.Character then
		personalLight(player.Character)
	end
	local _ = grain
end

return Atmosphere
