--!strict
-- On-screen HUD: objective, live threats, team status, toasts, pager,
-- carrying hint, downed / restore / ending overlays and the loading card.
-- Scale-based layout with text-size constraints so it reads on phones.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local Dialogue = require(ReplicatedStorage.Shared.Dialogue)
local Types = require(ReplicatedStorage.Shared.Types)
local State = require(script.Parent.State)
local Desktop = require(script.Parent.Desktop)
local UiKit = require(script.Parent.Parent.Ui.UiKit)

local player = Players.LocalPlayer

local Hud = {}

local gui: ScreenGui
local objectivePanel: Frame
local objectiveText: TextLabel
local progressText: TextLabel
local threatList: Frame
local teamList: Frame
local toastStack: Frame
local carryLabel: TextLabel
local downedOverlay: Frame
local downedText: TextLabel
local fade: Frame
local fadeText: TextLabel
local ending: Frame
local loading: Frame
local hints: TextLabel

local PANEL = Color3.fromRGB(14, 16, 20)

local function textConstraint(parent: Instance, maxSize: number, minSize: number?)
	UiKit.new("UITextSizeConstraint", { MaxTextSize = maxSize, MinTextSize = minSize or 9, Parent = parent })
end

local function panel(props: { [string]: any }): Frame
	local p = table.clone(props)
	p.BackgroundColor3 = p.BackgroundColor3 or PANEL
	p.BackgroundTransparency = p.BackgroundTransparency or 0.25
	local f = UiKit.frame(p)
	UiKit.new("UICorner", { CornerRadius = UDim.new(0, 6), Parent = f })
	UiKit.new("UIPadding", {
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 8),
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 6),
		Parent = f,
	})
	return f
end

function Hud.toast(text: string, kind: string?)
	local color = if kind == "bad" then Color3.fromRGB(150, 30, 30) elseif kind == "good" then Color3.fromRGB(30, 110, 50) else Color3.fromRGB(30, 50, 90)
	local f = panel({ Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = color, BackgroundTransparency = 0.1, LayoutOrder = math.floor(os.clock() * 100), Parent = toastStack })
	local l = UiKit.label({
		Text = text,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 17,
		Font = UiKit.FONT_BOLD,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = f,
	})
	local _ = l
	local children = toastStack:GetChildren()
	local frames = 0
	for _, c in children do
		if c:IsA("Frame") then
			frames += 1
		end
	end
	if frames > 4 then
		for _, c in children do
			if c:IsA("Frame") and c ~= f then
				c:Destroy()
				break
			end
		end
	end
	task.delay(5, function()
		if f.Parent then
			TweenService:Create(f, UiKit.FADE, { BackgroundTransparency = 1 }):Play()
			task.wait(0.35)
			f:Destroy()
		end
	end)
end

local function renderThreats(snap: Types.Snapshot)
	UiKit.clear(threatList) -- keeps the UIListLayout created in build()
	for i, t in snap.threats do
		local f = panel({
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = if t.urgent then Color3.fromRGB(120, 20, 20) else Color3.fromRGB(70, 60, 20),
			BackgroundTransparency = 0.15,
			LayoutOrder = if t.urgent then i else 100 + i,
			Parent = threatList,
		})
		UiKit.label({
			Text = (if t.urgent then "! " else "- ") .. t.label .. (if t.where then "  [" .. t.where .. "]" else ""),
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextColor3 = Color3.new(1, 1, 1),
			Font = UiKit.FONT_BOLD,
			TextSize = 16,
			Parent = f,
		})
	end
end

local function renderTeam(snap: Types.Snapshot)
	UiKit.clear(teamList)
	for i, p in Players:GetPlayers() do
		local status = ""
		if p:GetAttribute("Downed") == true then
			status = "  CAUGHT - help!"
		elseif p:GetAttribute("Escaped") == true then
			status = "  escaped"
		elseif p:GetAttribute("ClockedOut") == true then
			status = "  clocked out"
		elseif snap.operator == p.DisplayName then
			status = "  at the PC"
		elseif typeof(p:GetAttribute("Carrying")) == "string" then
			status = "  carrying " .. tostring(p:GetAttribute("Carrying"))
		end
		UiKit.label({
			Text = p.DisplayName .. status,
			Size = UDim2.new(1, 0, 0, 18),
			TextColor3 = if p:GetAttribute("Downed") == true then Color3.fromRGB(255, 120, 110) else Color3.fromRGB(220, 220, 220),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextSize = 15,
			Font = UiKit.FONT_BOLD,
			LayoutOrder = i,
			Parent = teamList,
		})
	end
end

local function render(snap: Types.Snapshot)
	objectiveText.Text = snap.objective
	progressText.Text = string.format("%s   |   ERASED %d/%d   |   %s", State.nightClock(snap.nightMinutes), snap.erased, snap.total, if snap.soloMode then "SOLO" else #Players:GetPlayers() .. " ON SHIFT")
	renderThreats(snap)
	renderTeam(snap)
	local carrying = player:GetAttribute("Carrying")
	if typeof(carrying) == "string" then
		local where = if carrying == "TrashBag" then "the alley DUMPSTER (rear door)" elseif carrying == "Printout" then "the OUT TRAY on the corner desk" else "the workstation DOCK or the drive RACK"
		carryLabel.Text = "Carrying " .. carrying .. "  ->  " .. where
		carryLabel.Visible = true
	else
		carryLabel.Visible = false
	end
	objectivePanel.Visible = not Desktop.isOpen()
end

local function showFade(text: string, hold: number)
	fade.Visible = true
	fade.BackgroundTransparency = 1
	fadeText.Text = text
	fadeText.TextTransparency = 1
	TweenService:Create(fade, TweenInfo.new(0.8), { BackgroundTransparency = 0 }):Play()
	TweenService:Create(fadeText, TweenInfo.new(0.8), { TextTransparency = 0 }):Play()
	task.delay(hold, function()
		TweenService:Create(fade, TweenInfo.new(1.2), { BackgroundTransparency = 1 }):Play()
		TweenService:Create(fadeText, TweenInfo.new(1.2), { TextTransparency = 1 }):Play()
		task.wait(1.3)
		fade.Visible = false
	end)
end

local function showEnding(data: any)
	ending.Visible = true
	UiKit.clear(ending)
	ending.BackgroundTransparency = 1
	TweenService:Create(ending, TweenInfo.new(2), { BackgroundTransparency = 0 }):Play()
	local title = UiKit.label({ Text = data.title, Size = UDim2.fromScale(1, 0.15), Position = UDim2.fromScale(0, 0.12), TextColor3 = Color3.fromRGB(230, 220, 200), Font = Enum.Font.Arcade, TextScaled = true, TextXAlignment = Enum.TextXAlignment.Center, Parent = ending })
	textConstraint(title, 90)
	for i, line in data.lines :: { string } do
		local l = UiKit.label({
			Text = line,
			Size = UDim2.fromScale(0.8, 0.07),
			Position = UDim2.fromScale(0.1, 0.32 + i * 0.08),
			TextColor3 = Color3.fromRGB(200, 200, 190),
			TextTransparency = 1,
			TextScaled = true,
			TextXAlignment = Enum.TextXAlignment.Center,
			Parent = ending,
		})
		textConstraint(l, 28)
		task.delay(1.5 + i * 2.2, function()
			TweenService:Create(l, TweenInfo.new(1.5), { TextTransparency = 0 }):Play()
		end)
	end
	local stats = UiKit.label({
		Text = string.format("%s  -  shift length %d:%02d  -  thanks for playing", Config.GAME_TITLE, data.minutes or 0, data.seconds or 0),
		Size = UDim2.fromScale(0.9, 0.05),
		Position = UDim2.fromScale(0.05, 0.86),
		TextColor3 = Color3.fromRGB(140, 140, 130),
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = ending,
	})
	textConstraint(stats, 20)
	task.delay(Config.PHASE.endingSeconds - 2, function()
		TweenService:Create(ending, TweenInfo.new(1.5), { BackgroundTransparency = 1 }):Play()
		for _, c in ending:GetChildren() do
			if c:IsA("TextLabel") then
				TweenService:Create(c, TweenInfo.new(1.5), { TextTransparency = 1 }):Play()
			end
		end
		task.wait(1.6)
		ending.Visible = false
	end)
end

local function build()
	gui = UiKit.new("ScreenGui", { Name = "Hud", ResetOnSpawn = false, DisplayOrder = 6, IgnoreGuiInset = false, Parent = player:WaitForChild("PlayerGui") })

	objectivePanel = panel({ Size = UDim2.new(0.34, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Position = UDim2.new(0, 12, 0, 12), Parent = gui })
	UiKit.new("UISizeConstraint", { MinSize = Vector2.new(260, 0), MaxSize = Vector2.new(520, 400), Parent = objectivePanel })
	UiKit.new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = objectivePanel })
	UiKit.label({ Text = "OBJECTIVE", Size = UDim2.new(1, 0, 0, 16), TextColor3 = Color3.fromRGB(240, 200, 110), Font = UiKit.FONT_BOLD, TextSize = 14, LayoutOrder = 1, Parent = objectivePanel })
	objectiveText = UiKit.label({ Text = "", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextColor3 = Color3.new(1, 1, 1), Font = UiKit.FONT_BOLD, TextSize = 18, LayoutOrder = 2, Parent = objectivePanel })
	progressText = UiKit.label({ Text = "", Size = UDim2.new(1, 0, 0, 18), TextColor3 = Color3.fromRGB(170, 180, 190), TextSize = 14, LayoutOrder = 3, Parent = objectivePanel })

	threatList = UiKit.frame({ Name = "Threats", Size = UDim2.new(0.3, 0, 0.4, 0), Position = UDim2.new(0, 12, 0, 132), BackgroundTransparency = 1, Parent = gui })
	UiKit.new("UISizeConstraint", { MinSize = Vector2.new(240, 0), MaxSize = Vector2.new(460, 400), Parent = threatList })
	UiKit.new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = threatList })

	teamList = UiKit.frame({ Name = "Team", Size = UDim2.new(0.25, 0, 0, 90), Position = UDim2.new(1, -12, 0, 12), AnchorPoint = Vector2.new(1, 0), BackgroundTransparency = 1, Parent = gui })
	UiKit.new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = teamList })

	toastStack = UiKit.frame({ Name = "Toasts", Size = UDim2.new(0.5, 0, 0.3, 0), Position = UDim2.new(0.5, 0, 0.62, 0), AnchorPoint = Vector2.new(0.5, 0), BackgroundTransparency = 1, Parent = gui })
	UiKit.new("UISizeConstraint", { MinSize = Vector2.new(300, 0), MaxSize = Vector2.new(640, 400), Parent = toastStack })
	UiKit.new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Top, Parent = toastStack })

	carryLabel = UiKit.label({ Text = "", Size = UDim2.new(0.6, 0, 0, 30), Position = UDim2.new(0.5, 0, 1, -110), AnchorPoint = Vector2.new(0.5, 0), BackgroundTransparency = 0.3, BackgroundColor3 = PANEL, TextColor3 = Color3.fromRGB(255, 230, 150), Font = UiKit.FONT_BOLD, TextSize = 18, TextXAlignment = Enum.TextXAlignment.Center, Visible = false, Parent = gui })
	UiKit.new("UICorner", { CornerRadius = UDim.new(0, 6), Parent = carryLabel })

	hints = UiKit.label({ Text = "[E] take / use   [F] place drive   [G] ping   [Space] stand up", Size = UDim2.new(0.5, 0, 0, 18), Position = UDim2.new(0.5, 0, 1, -24), AnchorPoint = Vector2.new(0.5, 0), TextColor3 = Color3.fromRGB(150, 150, 150), TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center, Parent = gui })

	downedOverlay = UiKit.frame({ Name = "Downed", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(60, 0, 0), BackgroundTransparency = 0.55, Visible = false, ZIndex = 50, Parent = gui })
	downedText = UiKit.label({ Text = "", Size = UDim2.fromScale(0.8, 0.2), Position = UDim2.fromScale(0.1, 0.4), TextColor3 = Color3.new(1, 0.9, 0.9), TextScaled = true, Font = UiKit.FONT_BOLD, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 51, Parent = downedOverlay })
	textConstraint(downedText, 34)

	-- full-screen fades sit above the desktop too
	local top = UiKit.new("ScreenGui", { Name = "HudTop", ResetOnSpawn = false, DisplayOrder = 20, IgnoreGuiInset = true, Parent = player:WaitForChild("PlayerGui") })
	fade = UiKit.frame({ Name = "Fade", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), Visible = false, Parent = top })
	fadeText = UiKit.label({ Text = "", Size = UDim2.fromScale(0.8, 0.12), Position = UDim2.fromScale(0.1, 0.44), TextColor3 = Color3.fromRGB(220, 210, 190), TextScaled = true, Font = Enum.Font.Arcade, TextXAlignment = Enum.TextXAlignment.Center, Parent = fade })
	textConstraint(fadeText, 40)
	ending = UiKit.frame({ Name = "Ending", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), Visible = false, Parent = top })
	loading = UiKit.frame({ Name = "Loading", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(6, 6, 8), Parent = top })
	local lt = UiKit.label({ Text = Config.GAME_TITLE, Size = UDim2.fromScale(0.9, 0.12), Position = UDim2.fromScale(0.05, 0.36), TextColor3 = Color3.fromRGB(220, 210, 190), TextScaled = true, Font = Enum.Font.Arcade, TextXAlignment = Enum.TextXAlignment.Center, Parent = loading })
	textConstraint(lt, 72)
	local ls = UiKit.label({ Text = "clocking in...  " .. Dialogue.COMPANY .. " - night operations", Size = UDim2.fromScale(0.9, 0.05), Position = UDim2.fromScale(0.05, 0.52), TextColor3 = Color3.fromRGB(150, 150, 140), TextScaled = true, TextXAlignment = Enum.TextXAlignment.Center, Parent = loading })
	textConstraint(ls, 24)
end

function Hud.init()
	build()
	State.Changed:Connect(render)
	State.Notified:Connect(function(text, kind)
		Hud.toast(text, kind)
	end)
	State.SessionChanged:Connect(function()
		task.defer(function() -- after the desktop has opened/closed
			local open = Desktop.isOpen()
			objectivePanel.Visible = not open
			hints.Visible = not open
			-- alerts stay visible while seated, moved clear of the desktop icons
			threatList.AnchorPoint = if open then Vector2.new(1, 0) else Vector2.zero
			threatList.Position = if open then UDim2.new(1, -16, 0, 110) else UDim2.new(0, 12, 0, 132)
		end)
	end)
	State.Fx:Connect(function(name, data)
		if name == "BossMessage" and not Desktop.isOpen() then
			Hud.toast("PAGER  " .. data.from .. ": " .. data.text, if data.kind == "false" then "bad" else "info")
		elseif name == "Fragment" and not Desktop.isOpen() then
			local f = Dialogue.FRAGMENTS[data.index]
			if f then
				Hud.toast("Recovered before shredding: " .. f.title .. " (read it in My Files at the workstation)", "info")
			end
		elseif name == "CheckpointSaved" then
			Hud.toast("Checkpoint: " .. tostring(data.label), "good")
		elseif name == "Restore" then
			showFade("CHECKPOINT\n" .. tostring(data.reason), 2.2)
		elseif name == "TeamCaught" then
			downedText.Text = if data.solo then "You were caught.\nReturning to the last checkpoint..." else "Everyone was caught.\nReturning to the last checkpoint..."
		elseif name == "Ending" then
			showEnding(data)
		elseif name == "Escaped" and data.name == player.DisplayName then
			Hud.toast("You made it outside. Wait for the others.", "good")
		end
	end)
	player:GetAttributeChangedSignal("Downed"):Connect(function()
		local downed = player:GetAttribute("Downed") == true
		downedOverlay.Visible = downed
		if downed then
			downedText.Text = if #Players:GetPlayers() <= 1 then "You were caught.\nReturning to the last checkpoint..." else "You were caught.\nA teammate can help you up (hold E near you)."
		end
	end)
	player:GetAttributeChangedSignal("Carrying"):Connect(function()
		if State.snapshot then
			render(State.snapshot)
		end
	end)
end

function Hud.start()
	-- loading card until the art is baked (or a short timeout)
	local t0 = os.clock()
	while workspace:GetAttribute("ClientArtReady") ~= true and os.clock() - t0 < 25 do
		task.wait(0.2)
	end
	TweenService:Create(loading, TweenInfo.new(1.5), { BackgroundTransparency = 1 }):Play()
	for _, c in loading:GetChildren() do
		if c:IsA("TextLabel") then
			TweenService:Create(c, TweenInfo.new(1.5), { TextTransparency = 1 }):Play()
		end
	end
	task.wait(1.6)
	loading.Visible = false
	-- periodic refresh keeps team status in sync with attribute changes
	while true do
		task.wait(1)
		if State.snapshot then
			renderTeam(State.snapshot)
		end
	end
end

return Hud
