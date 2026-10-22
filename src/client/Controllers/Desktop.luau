--!strict
-- The workstation desktop: a native-GUI, early-2000s style OS shell that
-- hosts every SecureErase utility. Opens when the server starts a session
-- for this player and closes the moment the session ends. Everything here is
-- presentation: actions are sent to the server as semantic commands tagged
-- with the session id, and the server answers with the authoritative state.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local Dialogue = require(ReplicatedStorage.Shared.Dialogue)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)
local State = require(script.Parent.State)
local UiKit = require(script.Parent.Parent.Ui.UiKit)

local C = UiKit.C
local player = Players.LocalPlayer

local Views: { [string]: any } = {}
for _, m in script.Parent.Parent:WaitForChild("Views"):GetChildren() do
	if m:IsA("ModuleScript") then
		Views[m.Name] = (require :: any)(m)
	end
end

local Desktop = {}

local W, H = 960, 600

local gui: ScreenGui
local bezel: Frame
local canvas: Frame
local canvasScale: UIScale
local windowsLayer: Frame
local mainWin: UiKit.Window
local mainParts: {
	header: TextLabel,
	stage: TextLabel,
	progressFill: Frame,
	instructions: TextLabel,
	game: Frame,
	feedback: TextLabel,
	hint: TextLabel,
	overlay: Frame,
	overlayText: TextLabel,
}
local side: { [string]: UiKit.Window } = {}
local sideOpen: { [string]: boolean } = {}
local taskbarTray: { erased: TextLabel, door: TextLabel, power: TextLabel, clock: TextLabel }
local startMenu: Frame
local toast: Frame
local toastText: TextLabel
local phantomFrame: Frame?
local fragmentWin: UiKit.Window?
local leaveButton: TextButton

local isOpen = false
local session: Types.SessionPayload? = nil
local lastViewKey = ""
local zTop = 20
local filesSelection: number? = nil
local sideKeys: { [string]: string } = {}
local finaleKey = ""

-- cheap content signature per side app, so snapshots that change nothing
-- relevant do not rebuild the window (scroll position and focus survive)
local function sideKey(name: string, snap: Types.Snapshot): string
	if name == "Messenger" then
		local last = snap.boss[#snap.boss]
		local open = 0
		for _, m in snap.boss do
			if m.answered then
				open += 1
			end
		end
		return string.format("%d:%s:%d", #snap.boss, if last then tostring(last.id) else "-", open)
	elseif name == "DriveInfo" then
		local parts = {}
		for _, d in snap.drives do
			table.insert(parts, d.state .. math.floor(d.progress * 20) .. (d.carrier or ""))
		end
		return table.concat(parts, "|")
	end
	return "static"
end

local function finaleSignature(snap: Types.Snapshot): string
	local parts: { string } = { snap.phase :: string, tostring(snap.power.workstation) }
	if snap.purge then
		for _, e in snap.purge do
			table.insert(parts, e.name .. tostring(e.cancelled))
		end
		table.insert(parts, tostring(math.floor(snap.purgeDeadline or 0)))
	end
	if snap.signOff then
		table.insert(parts, tostring(math.floor(snap.signOff.progress * 100)) .. tostring(snap.signOff.awaiting))
	end
	return table.concat(parts, ";")
end

local function send(kind: string, a: any?, b: any?, c: any?)
	local s = session
	if not s then
		return
	end
	Net.remote("Desktop"):FireServer(s.sessionId, kind, a, b, c)
end

function Desktop.leave()
	Net.remote("Leave"):FireServer()
	local character = player.Character
	local h = character and character:FindFirstChildOfClass("Humanoid")
	if h then
		h.Sit = false
		h.Jump = true
	end
end

-- ZIndexBehavior is Sibling, so raising the window frame raises the window.
local function bringToFront(w: UiKit.Window)
	zTop += 1
	w.frame.ZIndex = zTop
	if phantomFrame then
		phantomFrame.ZIndex = zTop + 100
	end
end

-- Side applications ---------------------------------------------------------

local renderSide: (name: string) -> ()

local function openSide(name: string)
	local w = side[name]
	if not w then
		return
	end
	sideOpen[name] = true
	w.frame.Visible = true
	bringToFront(w)
	renderSide(name)
	startMenu.Visible = false
end

local function closeSide(name: string)
	sideOpen[name] = false
	local w = side[name]
	if w then
		w.frame.Visible = false
	end
end

local function listLabel(parent: Instance, text: string, y: number, h: number, z: number, opts: { [string]: any }?): TextLabel
	local p: { [string]: any } = {
		Text = text,
		Size = UDim2.new(1, -16, 0, h),
		Position = UDim2.fromOffset(8, y),
		TextSize = 15,
		ZIndex = z,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = parent,
	}
	local extra: { [string]: any } = opts or {}
	for k, v in extra do
		p[k] = v
	end
	return UiKit.label(p)
end

renderSide = function(name: string)
	local w = side[name]
	local snap = State.snapshot
	if not w or not sideOpen[name] or not snap then
		return
	end
	local body = w.body
	UiKit.clear(body)
	local z = w.frame.ZIndex + 2
	local paper = UiKit.frame({ Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.field, ZIndex = z, Parent = body })
	UiKit.bevel(paper, true)
	local scroll = UiKit.new("ScrollingFrame", {
		Size = UDim2.new(1, -6, 1, -6),
		Position = UDim2.fromOffset(3, 3),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 10,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ZIndex = z + 1,
		Parent = paper,
	}) :: ScrollingFrame
	local y = 6
	if name == "Messenger" then
		for _, m in snap.boss do
			local tint = if m.kind == "false" then Color3.fromRGB(140, 30, 30) elseif m.kind == "system" then Color3.fromRGB(20, 80, 30) else C.info
			listLabel(scroll, string.format("[%s] %s:", State.nightClock(m.t), m.from), y, 18, z + 2, { Font = UiKit.FONT_BOLD, TextColor3 = tint })
			y += 18
			local lbl = listLabel(scroll, m.text, y, 40, z + 2, { AutomaticSize = Enum.AutomaticSize.Y })
			y += math.max(40, lbl.TextBounds.Y + 6)
			if m.choices and not m.answered then
				for i, choice in m.choices do
					UiKit.button({
						text = choice,
						size = UDim2.fromOffset(180, 30),
						position = UDim2.fromOffset(8 + (i - 1) * 188, y),
						parent = scroll,
						color = if i == 1 then C.face else Color3.fromRGB(230, 220, 190),
						textSize = 14,
						zindex = z + 2,
						onClick = function()
							send("bossReply", m.id, i)
						end,
					})
				end
				y += 36
			elseif m.answered then
				listLabel(scroll, "> " .. m.answered, y, 18, z + 2, { TextColor3 = C.faceDark, TextSize = 13 })
				y += 20
			end
			y += 6
		end
		scroll.CanvasPosition = Vector2.new(0, 100000)
	elseif name == "Procedures" then
		listLabel(scroll, "PROCEDURES.TXT - Night Operations (rev. 2006)", y, 22, z + 2, { Font = UiKit.FONT_BOLD })
		y += 28
		for _, line in Dialogue.PROCEDURES do
			local l = listLabel(scroll, line, y, 40, z + 2, { Font = UiKit.FONT_MONO, TextSize = 15 })
			y += math.max(40, l.TextBounds.Y + 8)
		end
		listLabel(scroll, "If an instruction contradicts these procedures, reject it and cite the number.", y + 6, 40, z + 2, { TextColor3 = C.bad, TextSize = 14 })
	elseif name == "Files" then
		listLabel(scroll, "C:\\RECOVERED\\  (fragments saved before shredding)", y, 20, z + 2, { Font = UiKit.FONT_BOLD })
		y += 26
		if #snap.fragments == 0 then
			listLabel(scroll, "(empty)", y, 20, z + 2, { TextColor3 = C.faceDark })
		end
		for _, idx in snap.fragments do
			local f = Dialogue.FRAGMENTS[idx]
			if f then
				UiKit.button({
					text = string.format("%02d  %s   (%s)", idx, f.title, f.kind),
					size = UDim2.new(1, -24, 0, 28),
					position = UDim2.fromOffset(8, y),
					parent = scroll,
					color = if filesSelection == idx then Color3.fromRGB(200, 215, 240) else C.field,
					textSize = 14,
					font = UiKit.FONT,
					zindex = z + 2,
					bevel = false,
					onClick = function()
						filesSelection = idx
						renderSide("Files")
					end,
				}).TextXAlignment = Enum.TextXAlignment.Left
				y += 30
				if filesSelection == idx then
					local l = listLabel(scroll, f.body, y, 80, z + 2, { Font = UiKit.FONT_MONO, TextSize = 14, BackgroundTransparency = 0, BackgroundColor3 = Color3.fromRGB(250, 248, 236) })
					y += math.max(80, l.TextBounds.Y + 10)
				end
			end
		end
	elseif name == "DriveInfo" then
		listLabel(scroll, "DRIVE MANAGER - team job status", y, 20, z + 2, { Font = UiKit.FONT_BOLD })
		y += 26
		listLabel(scroll, string.format("Erased: %d of %d", snap.erased, snap.total), y, 20, z + 2)
		y += 24
		for _, d in snap.drives do
			local where = d.state
			if d.carrier then
				where = "Carried by " .. d.carrier
			end
			local pct = math.floor(d.progress * 100)
			listLabel(scroll, string.format("%s  %-15s  %-22s %3d%%", d.id, d.name, where, pct), y, 20, z + 2, {
				Font = UiKit.FONT_MONO,
				TextSize = 13,
				TextColor3 = if d.state == "Erased" then C.good else C.text,
			})
			y += 22
			if d.gameTitle then
				listLabel(scroll, "      utility: " .. d.gameTitle, y, 18, z + 2, { TextSize = 12, TextColor3 = C.faceDark })
				y += 20
			end
		end
	end
end

-- Main SecureErase window ----------------------------------------------------

local function setFeedback(text: string?, kind: string?)
	mainParts.feedback.Text = text or ""
	mainParts.feedback.TextColor3 = if kind == "bad" then C.bad elseif kind == "good" then C.good else C.info
end

local function renderFinale(snap: Types.Snapshot)
	local g = mainParts.game
	UiKit.clear(g)
	local z = g.ZIndex
	if snap.phase == "FinalPurge" and snap.purge then
		local left = math.floor(snap.purgeDeadline or 0)
		finaleKey = finaleSignature(snap)
		mainWin.title.Text = "SecureErase :: FINAL PURGE QUEUE"
		mainParts.header.Text = "AUTOMATIC FINAL PURGE: EMPLOYEE RECORDS"
		mainParts.stage.Text = string.format("Executes in %d:%02d", left // 60, left % 60)
		mainParts.instructions.Text = "The final purge includes YOUR employee records. Cancel every entry from tonight, then run EMERGENCY SIGN-OFF."
		local allDone = true
		for i, e in snap.purge do
			local row = UiKit.frame({ Size = UDim2.new(1, 0, 0, 26), Position = UDim2.fromOffset(0, (i - 1) * 28), BackgroundColor3 = if e.locked then Color3.fromRGB(200, 196, 190) else C.field, ZIndex = z, Parent = g })
			UiKit.label({ Text = e.name, Size = UDim2.new(0.6, 0, 1, 0), Position = UDim2.fromOffset(8, 0), Font = UiKit.FONT_MONO, TextSize = 14, ZIndex = z + 1, Parent = row })
			if e.locked then
				UiKit.label({ Text = "PURGED 03-NOV-2003", Size = UDim2.new(0.38, 0, 1, 0), Position = UDim2.fromScale(0.6, 0), TextColor3 = C.bad, TextSize = 13, ZIndex = z + 1, Parent = row })
			elseif e.cancelled then
				UiKit.label({ Text = "REMOVED FROM QUEUE", Size = UDim2.new(0.38, 0, 1, 0), Position = UDim2.fromScale(0.6, 0), TextColor3 = C.good, Font = UiKit.FONT_BOLD, TextSize = 13, ZIndex = z + 1, Parent = row })
			else
				allDone = false
				UiKit.button({
					text = "CANCEL",
					size = UDim2.new(0.25, 0, 1, -2),
					position = UDim2.fromScale(0.72, 0),
					parent = row,
					color = C.bad,
					textColor = C.white,
					textSize = 14,
					zindex = z + 2,
					onClick = function()
						send("purgeCancel", i)
					end,
				})
			end
		end
		local run = UiKit.button({
			text = "RUN EMERGENCY SIGN-OFF",
			size = UDim2.fromOffset(300, 40),
			position = UDim2.new(0.5, -150, 1, -42),
			parent = g,
			color = if allDone then C.good else C.faceDark,
			textColor = C.white,
			zindex = z + 2,
			onClick = function()
				send("signOffStart")
			end,
		})
		UiKit.setEnabled(run, allDone)
		mainParts.progressFill.Size = UDim2.fromScale(1 - math.clamp(left / 150, 0, 1), 1)
		mainParts.progressFill.BackgroundColor3 = C.bad
	elseif snap.phase == "SignOff" and snap.signOff then
		local s = snap.signOff
		mainWin.title.Text = "SecureErase :: EMERGENCY SIGN-OFF"
		mainParts.header.Text = "Writing tonight's timesheets to the off-site backup"
		mainParts.stage.Text = string.format("%d%%", math.floor(s.progress * 100))
		mainParts.instructions.Text = "Keep the workstation powered. At each checkpoint the operator must CONFIRM. Power loss pauses the sign-off; it never resets."
		mainParts.progressFill.Size = UDim2.fromScale(s.progress, 1)
		mainParts.progressFill.BackgroundColor3 = C.good
		local status = if not snap.power.workstation then "PAUSED - no power" elseif s.awaiting then "PAUSED - confirmation required" else "Running..."
		UiKit.label({ Text = status, Size = UDim2.new(1, 0, 0, 40), Position = UDim2.fromOffset(0, 20), TextXAlignment = Enum.TextXAlignment.Center, Font = UiKit.FONT_BOLD, TextSize = 24, ZIndex = z, Parent = g })
		if s.awaiting then
			UiKit.button({
				text = "CONFIRM CHECKPOINT",
				size = UDim2.fromOffset(320, 70),
				position = UDim2.new(0.5, -160, 0, 90),
				parent = g,
				color = C.good,
				textColor = C.white,
				textSize = 22,
				zindex = z + 1,
				onClick = function()
					send("signOffConfirm")
				end,
			})
		end
	elseif snap.phase == "ClockOut" or snap.phase == "Ending" then
		mainWin.title.Text = "SecureErase"
		mainParts.header.Text = "SIGN-OFF COMPLETE"
		mainParts.stage.Text = ""
		mainParts.instructions.Text = "Your records are safe off-site. Leave the computer, clock out at the lobby time clock and get out."
		mainParts.progressFill.Size = UDim2.fromScale(1, 1)
	end
end

local function renderMain()
	local s = session
	local snap = State.snapshot
	if not s or not snap then
		return
	end
	mainParts.hint.Text = s.hint or ""
	setFeedback(s.feedback, s.feedbackKind)
	local noPower = s.reason == "power" or not snap.power.workstation
	mainParts.overlay.Visible = noPower
	if noPower then
		mainParts.overlayText.Text = "SecureErase - Device not ready\n\nThe workstation has lost power.\nReset the tripped breaker (MAIN / WORKSTATION) at the panel in the UTILITY HALL.\n\nYour progress is saved."
	end
	if snap.phase == "FinalPurge" or snap.phase == "SignOff" or snap.phase == "ClockOut" or snap.phase == "Ending" then
		lastViewKey = "finale"
		renderFinale(snap)
		return
	end
	mainWin.title.Text = s.title or "SecureErase 2.1"
	mainParts.progressFill.BackgroundColor3 = Color3.fromRGB(40, 170, 60)
	local g = mainParts.game
	if not s.driveId then
		lastViewKey = "nodrive"
		UiKit.clear(g)
		mainParts.header.Text = "No drive connected"
		mainParts.stage.Text = ""
		mainParts.instructions.Text = "Dock a hard drive at the DOCK on this desk (a teammate can bring one from the rack). Use the desktop apps meanwhile."
		mainParts.progressFill.Size = UDim2.fromScale(0, 1)
		UiKit.label({
			Text = string.format("Team progress: %d / %d drives erased", snap.erased, snap.total),
			Size = UDim2.new(1, 0, 0, 40),
			Position = UDim2.fromOffset(0, 80),
			TextXAlignment = Enum.TextXAlignment.Center,
			Font = UiKit.FONT_BOLD,
			TextSize = 22,
			ZIndex = g.ZIndex,
			Parent = g,
		})
		return
	end
	mainParts.header.Text = string.format("Connected: %s  %s", s.driveId, s.driveName or "")
	if not s.view then
		lastViewKey = "start"
		UiKit.clear(g)
		mainParts.stage.Text = "Ready"
		mainParts.instructions.Text = s.instructions or ""
		mainParts.progressFill.Size = UDim2.fromScale(0, 1)
		UiKit.button({
			name = "StartErase",
			text = "START SECURE ERASE",
			size = UDim2.fromOffset(320, 80),
			position = UDim2.new(0.5, -160, 0, 70),
			parent = g,
			color = C.good,
			textColor = C.white,
			textSize = 24,
			zindex = g.ZIndex + 1,
			onClick = function()
				send("start")
			end,
		})
		return
	end
	mainParts.stage.Text = if s.transitioning then "Erasing sectors..." else string.format("Stage %d / %d", s.stage, s.stages)
	mainParts.instructions.Text = s.instructions or ""
	local progress = s.progress or 0
	TweenService:Create(mainParts.progressFill, UiKit.FAST, { Size = UDim2.fromScale(progress, 1) }):Play()
	local view = s.view :: { [string]: any }
	local mod = Views[view.kind]
	if s.transitioning then
		UiKit.clear(g)
		UiKit.label({ Text = "Verifying stage... erasing sectors...", Size = UDim2.new(1, 0, 0, 40), Position = UDim2.fromOffset(0, 90), TextXAlignment = Enum.TextXAlignment.Center, Font = UiKit.FONT_BOLD, TextSize = 22, ZIndex = g.ZIndex, Parent = g })
		lastViewKey = "transition"
		return
	end
	if mod then
		lastViewKey = view.kind
		mod.render(g, view, {
			act = function(action: string, a: any, b: any)
				send("act", action, a, b)
			end,
		}, g.ZIndex + 1)
	end
end

local function renderPhantom()
	local s = session
	if phantomFrame then
		phantomFrame:Destroy()
		phantomFrame = nil
	end
	local p = s and s.phantom
	if not p or not isOpen then
		return
	end
	local z = 400
	local f = UiKit.frame({ Name = "Phantom", Size = UDim2.fromOffset(360, 200), Position = UDim2.fromOffset(math.floor(p.x * W), math.floor(p.y * H)), ZIndex = z, Parent = windowsLayer })
	UiKit.bevel(f)
	local bar = UiKit.frame({ Name = "Bar", Size = UDim2.new(1, -6, 0, 26), Position = UDim2.fromOffset(3, 3), BackgroundColor3 = Color3.fromRGB(120, 30, 30), ZIndex = z + 1, Parent = f })
	UiKit.new("UIGradient", { Color = ColorSequence.new(Color3.fromRGB(110, 24, 24), Color3.fromRGB(170, 90, 60)), Parent = bar })
	UiKit.button({
		name = "PhantomClose",
		text = "X",
		size = UDim2.fromOffset(24, 20),
		position = UDim2.fromOffset(3, 3),
		parent = bar,
		zindex = z + 3,
		textSize = 14,
		onClick = function()
			send("phantom", p.id, "close")
		end,
	})
	UiKit.label({ Text = "SecureErase.exe - [Not Responding]", Size = UDim2.new(1, -40, 1, 0), Position = UDim2.fromOffset(34, 0), TextColor3 = Color3.fromRGB(255, 220, 210), Font = UiKit.FONT_BOLD, TextSize = 15, ZIndex = z + 2, Parent = bar })
	UiKit.label({ Text = "THE QUEUE MUST BE FINISHED.\nDO NOT READ THE FILES.\nPress OK to continue.", Size = UDim2.new(1, -20, 0, 90), Position = UDim2.fromOffset(12, 40), TextSize = 16, Font = UiKit.FONT_MONO, ZIndex = z + 2, Parent = f })
	UiKit.button({
		text = "OK",
		size = UDim2.fromOffset(100, 34),
		position = UDim2.new(0.5, -50, 1, -44),
		parent = f,
		zindex = z + 2,
		onClick = function()
			send("phantom", p.id, "ok")
		end,
	})
	if p.first then
		UiKit.label({
			Text = "Not a real dialog: red title bar, X on the LEFT. Close it with that X.",
			Size = UDim2.new(1, 0, 0, 40),
			Position = UDim2.new(0, 0, 1, 4),
			BackgroundTransparency = 0,
			BackgroundColor3 = Color3.fromRGB(255, 255, 210),
			TextSize = 14,
			ZIndex = z + 2,
			Parent = f,
		})
	end
	phantomFrame = f
end

-- Snapshot-driven chrome -----------------------------------------------------

local function renderTray(snap: Types.Snapshot)
	taskbarTray.erased.Text = string.format("ERASED %d/%d", snap.erased, snap.total)
	taskbarTray.door.Text = if snap.door == "Latched" then "DOOR OK" else "DOOR OPEN!"
	taskbarTray.door.TextColor3 = if snap.door == "Latched" then Color3.fromRGB(180, 255, 180) else Color3.fromRGB(255, 120, 110)
	taskbarTray.power.Text = if snap.power.workstation and snap.power.lights then "PWR OK" else "PWR FAULT"
	taskbarTray.power.TextColor3 = if snap.power.workstation and snap.power.lights then Color3.fromRGB(180, 255, 180) else Color3.fromRGB(255, 120, 110)
	taskbarTray.clock.Text = State.nightClock(snap.nightMinutes)
end

local function showToast(from: string, text: string)
	toastText.Text = from .. ": " .. text
	toast.Visible = true
	toast.Position = UDim2.fromOffset(W - 330, H - 34)
	TweenService:Create(toast, UiKit.POP, { Position = UDim2.fromOffset(W - 330, H - 34 - 96) }):Play()
	local stamp = os.clock()
	toast:SetAttribute("Stamp", stamp)
	task.delay(7, function()
		if toast:GetAttribute("Stamp") == stamp then
			toast.Visible = false
		end
	end)
end

local function showFragment(index: number)
	local f = Dialogue.FRAGMENTS[index]
	if not f or not isOpen then
		return
	end
	if fragmentWin then
		fragmentWin.frame:Destroy()
	end
	local win = UiKit.window(windowsLayer, "Recovered before shredding - " .. f.title, UDim2.fromOffset(460, 250), UDim2.fromOffset(250, 150), 300, function()
		if fragmentWin then
			fragmentWin.frame:Destroy()
			fragmentWin = nil
		end
	end)
	fragmentWin = win
	local paper = UiKit.frame({ Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(250, 248, 236), ZIndex = 303, Parent = win.body })
	UiKit.label({ Text = f.kind:upper(), Size = UDim2.new(1, -16, 0, 20), Position = UDim2.fromOffset(8, 6), Font = UiKit.FONT_BOLD, TextColor3 = C.bad, ZIndex = 304, Parent = paper })
	UiKit.label({ Text = f.body, Size = UDim2.new(1, -16, 1, -40), Position = UDim2.fromOffset(8, 30), Font = UiKit.FONT_MONO, TextSize = 15, TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 304, Parent = paper })
	bringToFront(win)
end

-- Construction ---------------------------------------------------------------

local function build()
	gui = UiKit.new("ScreenGui", {
		Name = "Desktop",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 5,
		Enabled = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
	bezel = UiKit.frame({
		Name = "Bezel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.98, 0.98),
		BackgroundColor3 = Color3.fromRGB(196, 188, 166),
		Parent = gui,
	})
	UiKit.new("UIAspectRatioConstraint", { AspectRatio = 1.5, Parent = bezel })
	UiKit.new("UICorner", { CornerRadius = UDim.new(0.03, 0), Parent = bezel })
	local screen = UiKit.frame({
		Name = "Screen",
		Position = UDim2.fromScale(0.025, 0.03),
		Size = UDim2.fromScale(0.95, 0.85),
		BackgroundColor3 = Color3.new(0, 0, 0),
		ClipsDescendants = true,
		Parent = bezel,
	})
	canvas = UiKit.frame({
		Name = "Canvas",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(W, H),
		BackgroundColor3 = C.desktop,
		Parent = screen,
	})
	canvasScale = UiKit.new("UIScale", { Parent = canvas })
	local function rescale()
		local abs = screen.AbsoluteSize
		canvasScale.Scale = math.min(abs.X / W, abs.Y / H)
	end
	screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(rescale)
	rescale()
	UiKit.new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(0, 110, 118), Color3.fromRGB(0, 70, 86)),
		Rotation = 90,
		Parent = canvas,
	})
	UiKit.label({ Text = "MRR", Size = UDim2.fromOffset(300, 120), Position = UDim2.fromOffset(W - 330, 300), TextColor3 = Color3.fromRGB(0, 130, 140), TextSize = 110, Font = UiKit.FONT_BOLD, TextXAlignment = Enum.TextXAlignment.Right, Parent = canvas })
	UiKit.label({ Text = Dialogue.COMPANY, Size = UDim2.fromOffset(400, 24), Position = UDim2.fromOffset(W - 430, 410), TextColor3 = Color3.fromRGB(0, 140, 150), TextSize = 18, TextXAlignment = Enum.TextXAlignment.Right, Parent = canvas })

	-- icons
	local icons: { { any } } = {
		{ "SecureErase", "SE", C.good, function()
			bringToFront(mainWin)
		end },
		{ "Messenger", "IM", C.info, function()
			openSide("Messenger")
		end },
		{ "My Files", "MF", C.warn, function()
			openSide("Files")
		end },
		{ "Drive Info", "DI", Color3.fromRGB(110, 110, 120), function()
			openSide("DriveInfo")
		end },
		{ "Procedures.txt", "TXT", Color3.fromRGB(230, 230, 230), function()
			openSide("Procedures")
		end },
	}
	for i, ic in icons do
		local b = UiKit.button({
			name = "Icon_" .. ic[1],
			text = "",
			size = UDim2.fromOffset(86, 82),
			position = UDim2.fromOffset(10, 10 + (i - 1) * 90),
			parent = canvas,
			color = C.desktop,
			bevel = false,
			zindex = 2,
			onClick = ic[4],
		})
		b.BackgroundTransparency = 1
		local glyph = UiKit.frame({ Size = UDim2.fromOffset(44, 40), Position = UDim2.new(0.5, -22, 0, 4), BackgroundColor3 = ic[3], ZIndex = 3, Parent = b })
		UiKit.bevel(glyph)
		UiKit.label({ Text = ic[2], Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, Font = UiKit.FONT_BOLD, TextSize = 14, ZIndex = 5, Parent = glyph })
		UiKit.label({ Text = ic[1], Size = UDim2.new(1, 0, 0, 30), Position = UDim2.fromOffset(0, 48), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.white, TextSize = 13, ZIndex = 3, Parent = b })
	end

	windowsLayer = UiKit.frame({ Name = "Windows", Size = UDim2.new(1, 0, 1, -34), BackgroundTransparency = 1, ZIndex = 10, Parent = canvas })

	-- main SecureErase window (always open)
	mainWin = UiKit.window(windowsLayer, "SecureErase 2.1", UDim2.fromOffset(700, 504), UDim2.fromOffset(110, 14), 20, nil)
	mainWin.frame.Name = "MainWindow"
	local body = mainWin.body
	local z = 24
	local header = UiKit.label({ Text = "", Size = UDim2.new(1, -170, 0, 24), Position = UDim2.fromOffset(4, 2), Font = UiKit.FONT_BOLD, TextSize = 18, ZIndex = z, Parent = body })
	local stage = UiKit.label({ Text = "", Size = UDim2.fromOffset(160, 24), Position = UDim2.new(1, -164, 0, 2), Font = UiKit.FONT_BOLD, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Right, ZIndex = z, Parent = body })
	local _, fill = UiKit.progress(body, UDim2.new(1, -8, 0, 18), UDim2.fromOffset(4, 30), z)
	local instructions = UiKit.label({ Text = "", Size = UDim2.new(1, -8, 0, 40), Position = UDim2.fromOffset(4, 52), TextSize = 15, ZIndex = z, Parent = body })
	local game = UiKit.frame({ Name = "Game", Size = UDim2.fromOffset(620, 250), Position = UDim2.fromOffset(34, 98), BackgroundTransparency = 1, ZIndex = z, Parent = body })
	local feedback = UiKit.label({ Text = "", Size = UDim2.new(1, -8, 0, 22), Position = UDim2.fromOffset(4, 356), Font = UiKit.FONT_BOLD, TextSize = 16, ZIndex = z, Parent = body })
	local hint = UiKit.label({ Text = "", Size = UDim2.new(1, -8, 0, 40), Position = UDim2.fromOffset(4, 382), TextSize = 15, TextColor3 = Color3.fromRGB(150, 90, 0), ZIndex = z, Parent = body })
	local overlay = UiKit.frame({ Name = "NoPower", Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = Color3.fromRGB(0, 0, 40), BackgroundTransparency = 0.15, ZIndex = 60, Visible = false, Parent = body })
	local overlayText = UiKit.label({ Text = "", Size = UDim2.new(1, -40, 1, -40), Position = UDim2.fromOffset(20, 20), TextColor3 = C.white, TextSize = 20, Font = UiKit.FONT_BOLD, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 61, Parent = overlay })
	mainParts = {
		header = header,
		stage = stage,
		progressFill = fill,
		instructions = instructions,
		game = game,
		feedback = feedback,
		hint = hint,
		overlay = overlay,
		overlayText = overlayText,
	}

	-- side windows
	local sideDefs = {
		{ "Messenger", "MRR Messenger - R. Kessler" },
		{ "Files", "My Files - C:\\RECOVERED" },
		{ "DriveInfo", "Drive Manager" },
		{ "Procedures", "Procedures.txt - Notepad" },
	}
	for i, def in sideDefs do
		local nm = def[1]
		local w = UiKit.window(windowsLayer, def[2], UDim2.fromOffset(460, 440), UDim2.fromOffset(380 + i * 14, 20 + i * 12), 30 + i * 10, function()
			closeSide(nm)
		end)
		w.frame.Visible = false
		w.frame.Name = "Side_" .. nm
		side[nm] = w
	end

	-- taskbar
	local bar = UiKit.frame({ Name = "Taskbar", Size = UDim2.new(1, 0, 0, 34), Position = UDim2.new(0, 0, 1, -34), BackgroundColor3 = C.taskbar, ZIndex = 500, Parent = canvas })
	UiKit.new("UIGradient", { Color = ColorSequence.new(Color3.fromRGB(60, 110, 220), Color3.fromRGB(30, 70, 180)), Rotation = 90, Parent = bar })
	local startBtn = UiKit.button({
		name = "Start",
		text = "start",
		size = UDim2.fromOffset(96, 30),
		position = UDim2.fromOffset(2, 2),
		parent = bar,
		color = C.start,
		textColor = C.white,
		textSize = 18,
		zindex = 501,
		onClick = function()
			startMenu.Visible = not startMenu.Visible
		end,
	})
	local _s = startBtn
	local function trayLabel(x: number, w: number): TextLabel
		return UiKit.label({ Text = "", Size = UDim2.fromOffset(w, 34), Position = UDim2.new(1, x, 0, 0), TextColor3 = C.white, Font = UiKit.FONT_BOLD, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 502, Parent = bar })
	end
	taskbarTray = {
		erased = trayLabel(-440, 110),
		door = trayLabel(-325, 100),
		power = trayLabel(-220, 90),
		clock = trayLabel(-125, 120),
	}
	local trayBack = UiKit.frame({ Size = UDim2.fromOffset(450, 34), Position = UDim2.new(1, -450, 0, 0), BackgroundColor3 = Color3.fromRGB(20, 140, 220), BackgroundTransparency = 0.4, ZIndex = 501, Parent = bar })
	local _t = trayBack
	local taskButtons: { { any } } = { { "SecureErase", function()
		bringToFront(mainWin)
	end }, { "Messenger", function()
		openSide("Messenger")
	end } }
	for i, def in taskButtons do
		UiKit.button({
			text = def[1],
			size = UDim2.fromOffset(130, 28),
			position = UDim2.fromOffset(104 + (i - 1) * 136, 3),
			parent = bar,
			color = Color3.fromRGB(70, 130, 230),
			textColor = C.white,
			textSize = 14,
			zindex = 502,
			onClick = def[2],
		})
	end

	-- start menu
	startMenu = UiKit.frame({ Name = "StartMenu", Size = UDim2.fromOffset(240, 286), Position = UDim2.new(0, 0, 1, -34 - 286), BackgroundColor3 = C.face, Visible = false, ZIndex = 600, Parent = canvas })
	UiKit.bevel(startMenu)
	local side2 = UiKit.frame({ Size = UDim2.new(0, 28, 1, -4), Position = UDim2.fromOffset(2, 2), BackgroundColor3 = C.title1, ZIndex = 601, Parent = startMenu })
	local _side2 = side2
	local items: { { any } } = {
		{ "SecureErase", function()
			startMenu.Visible = false
			bringToFront(mainWin)
		end },
		{ "Messenger", function()
			openSide("Messenger")
		end },
		{ "My Files", function()
			openSide("Files")
		end },
		{ "Drive Info", function()
			openSide("DriveInfo")
		end },
		{ "Procedures.txt", function()
			openSide("Procedures")
		end },
		{ "Leave computer", function()
			startMenu.Visible = false
			Desktop.leave()
		end },
	}
	for i, it in items do
		UiKit.button({
			text = it[1],
			size = UDim2.new(1, -40, 0, 40),
			position = UDim2.fromOffset(34, 6 + (i - 1) * 46),
			parent = startMenu,
			color = if i == #items then Color3.fromRGB(230, 200, 200) else C.face,
			zindex = 602,
			onClick = it[2],
		}).TextXAlignment = Enum.TextXAlignment.Left
	end

	-- boss toast
	toast = UiKit.frame({ Name = "Toast", Size = UDim2.fromOffset(320, 90), Position = UDim2.fromOffset(W - 330, H - 130), BackgroundColor3 = Color3.fromRGB(255, 255, 225), Visible = false, ZIndex = 700, Parent = canvas })
	UiKit.bevel(toast)
	UiKit.label({ Text = "New message", Size = UDim2.new(1, -10, 0, 18), Position = UDim2.fromOffset(6, 4), Font = UiKit.FONT_BOLD, TextSize = 14, ZIndex = 701, Parent = toast })
	toastText = UiKit.label({ Text = "", Size = UDim2.new(1, -12, 1, -26), Position = UDim2.fromOffset(6, 22), TextSize = 14, TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 701, Parent = toast })
	local toastBtn = UiKit.new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", ZIndex = 702, Parent = toast }) :: TextButton
	toastBtn.Activated:Connect(function()
		toast.Visible = false
		openSide("Messenger")
	end)

	-- CRT-ish overlay: faint scanlines + vignette, kept readable
	local scan = UiKit.frame({ Name = "Scanlines", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 900, Parent = screen })
	scan.Active = false
	for y = 0, 59 do
		local l = UiKit.frame({ Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromScale(0, y / 60), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.94, ZIndex = 900, Parent = scan })
		l.Active = false
	end
	local vignette = UiKit.frame({ Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0, ZIndex = 901, Parent = screen })
	vignette.Active = false
	UiKit.new("UIGradient", {
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(0.12, 1), NumberSequenceKeypoint.new(0.88, 1), NumberSequenceKeypoint.new(1, 0.55) }),
		Parent = vignette,
	})

	-- bezel chin: brand, power LED and the always-visible leave button
	UiKit.label({ Text = "MRR-900  CRT", Size = UDim2.fromScale(0.3, 0.07), Position = UDim2.fromScale(0.04, 0.9), TextColor3 = Color3.fromRGB(110, 104, 90), Font = UiKit.FONT_BOLD, TextScaled = true, Parent = bezel })
	leaveButton = UiKit.button({
		name = "LeaveComputer",
		text = "LEAVE COMPUTER  [Space / B]",
		size = UDim2.fromScale(0.36, 0.075),
		position = UDim2.fromScale(0.6, 0.9),
		parent = bezel,
		color = Color3.fromRGB(170, 40, 40),
		textColor = C.white,
		zindex = 10,
		onClick = function()
			Desktop.leave()
		end,
	})
	leaveButton.TextScaled = true
	UiKit.new("UITextSizeConstraint", { MaxTextSize = 26, MinTextSize = 12, Parent = leaveButton })

	-- short landscape phones: drop the decorative bezel margins so the
	-- desktop canvas gets as many pixels as possible
	local aspect = bezel:FindFirstChildOfClass("UIAspectRatioConstraint")
	local function adapt()
		local vp = workspace.CurrentCamera.ViewportSize
		local compact = vp.Y < 520
		if aspect then
			aspect.Parent = if compact then nil else bezel
		end
		bezel.Size = if compact then UDim2.fromScale(1, 1) else UDim2.fromScale(0.98, 0.98)
		screen.Position = if compact then UDim2.fromScale(0.005, 0.005) else UDim2.fromScale(0.025, 0.03)
		screen.Size = if compact then UDim2.fromScale(0.99, 0.9) else UDim2.fromScale(0.95, 0.85)
		leaveButton.Position = if compact then UDim2.fromScale(0.6, 0.91) else UDim2.fromScale(0.6, 0.9)
		leaveButton.Size = if compact then UDim2.fromScale(0.39, 0.085) else UDim2.fromScale(0.36, 0.075)
		rescale()
	end
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(adapt)
	adapt()
end

-- Open / close ---------------------------------------------------------------

local function onLeaveAction(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		Desktop.leave()
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

-- Roblox chat would sit on top of the desktop and steal clicks while seated.
local chatWasEnabled: boolean? = nil
local function setChatVisible(visible: boolean)
	pcall(function()
		local TextChatService = game:GetService("TextChatService")
		local win = TextChatService:FindFirstChildOfClass("ChatWindowConfiguration")
		if win then
			if not visible then
				chatWasEnabled = win.Enabled
				win.Enabled = false
			elseif chatWasEnabled ~= nil then
				win.Enabled = chatWasEnabled
				chatWasEnabled = nil
			end
		end
	end)
end

local function open()
	if isOpen then
		return
	end
	isOpen = true
	setChatVisible(false)
	gui.Enabled = true
	local target = bezel.Size
	bezel.Size = UDim2.fromScale(target.X.Scale * 0.87, target.Y.Scale * 0.87)
	TweenService:Create(bezel, UiKit.POP, { Size = target }):Play()
	ContextActionService:BindActionAtPriority("NS_LeaveComputer", onLeaveAction, false, 3000, Enum.KeyCode.ButtonB, Enum.KeyCode.Backspace)
	GuiService.SelectedObject = leaveButton
	task.defer(function()
		local start = mainParts.game:FindFirstChildWhichIsA("GuiButton", true)
		if start and isOpen then
			GuiService.SelectedObject = start
		end
	end)
end

local function close()
	if not isOpen then
		return
	end
	isOpen = false
	gui.Enabled = false
	setChatVisible(true)
	startMenu.Visible = false
	ContextActionService:UnbindAction("NS_LeaveComputer")
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(gui) then
		GuiService.SelectedObject = nil
	end
	for name in sideOpen do
		closeSide(name)
	end
	if fragmentWin then
		fragmentWin.frame:Destroy()
		fragmentWin = nil
	end
	if phantomFrame then
		phantomFrame:Destroy()
		phantomFrame = nil
	end
end

function Desktop.isOpen(): boolean
	return isOpen
end

-- Standing up must return control instantly, even before the server answers.
function Desktop.forceClose()
	session = nil
	close()
end

function Desktop.init()
	build()
	State.SessionChanged:Connect(function(payload)
		if not payload.active then
			session = nil
			close()
			return
		end
		session = payload
		open()
		renderMain()
		renderPhantom()
	end)
	State.Changed:Connect(function(snap)
		renderTray(snap)
		if not isOpen then
			return
		end
		for name, isOpenNow in sideOpen do
			if isOpenNow and name ~= "Files" and name ~= "Procedures" then
				local key = sideKey(name, snap)
				if sideKeys[name] ~= key then
					sideKeys[name] = key
					renderSide(name)
				end
			end
		end
		-- the finale screens and the no-power overlay are snapshot-driven
		local finale = snap.phase == "FinalPurge" or snap.phase == "SignOff" or snap.phase == "ClockOut"
		if finale or lastViewKey == "finale" then
			local sig = finaleSignature(snap)
			if sig ~= finaleKey then
				finaleKey = sig
				renderMain()
			end
		elseif lastViewKey == "nodrive" or mainParts.overlay.Visible ~= (not snap.power.workstation) then
			renderMain()
		end
	end)
	State.Fx:Connect(function(name, data)
		if name == "BossMessage" and isOpen then
			showToast(data.from, data.text)
			if sideOpen.Messenger then
				renderSide("Messenger")
			end
		elseif name == "Fragment" and isOpen then
			showFragment(data.index)
		end
	end)
	-- the character can die / be reset while seated: close immediately
	player.CharacterRemoving:Connect(function()
		session = nil
		close()
	end)
	local _ = Config
end

return Desktop
