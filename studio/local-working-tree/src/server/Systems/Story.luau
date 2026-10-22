--!strict
-- Story progression: briefing, fragments revealed in a fixed order by erased
-- count, boss reactions, environmental dread, checkpoints after each drive
-- and the objective line shown to every player.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Dialogue = require(ReplicatedStorage.Shared.Dialogue)
local GameState = require(script.Parent.GameState)
local MapBuilder = require(script.Parent.MapBuilder)
local Drives = require(script.Parent.Drives)
local Checkpoints = require(script.Parent.Checkpoints)

local Story = {}

local briefingToken = 0

local function setDread(count: number)
	workspace:SetAttribute("Dread", math.clamp(count / Config.DRIVE_COUNT, 0, 1))
	local screens = MapBuilder.refs.sourceScreens
	-- a dead colleague's terminal wakes up for good late in the shift
	if count >= 4 and screens[2] then
		screens[2]:SetAttribute("Text", "D.MERRIN LOGGED IN")
	elseif screens[2] then
		screens[2]:SetAttribute("Text", nil)
	end
end

local function briefing()
	briefingToken += 1
	local my = briefingToken
	GameState.setPhase("Briefing")
	for i, line in Dialogue.INTRO do
		if briefingToken ~= my then
			return
		end
		GameState.bossMessage(line, "info")
		task.wait(if i == #Dialogue.INTRO then 2 else 4)
	end
	task.wait(math.max(0, Config.PHASE.briefingSeconds - 10))
	if briefingToken == my and GameState.phase == "Briefing" then
		GameState.setPhase("Work")
		GameState.bossMessage("Procedures are in the binder file on the desktop. Read them once.", "info")
	end
end

local function objective(): string
	local phase = GameState.phase
	local d = GameState.data
	if phase == "Briefing" then
		return "Clocking in... read Kessler's messages."
	elseif phase == "FinalPurge" then
		local left = if d.purgeDeadline then math.max(0, math.floor(d.purgeDeadline - os.clock())) else 0
		return string.format("CANCEL your records in the FINAL PURGE queue at the workstation (%d:%02d)", left // 60, left % 60)
	elseif phase == "SignOff" then
		local s = d.signOff
		if s and s.awaiting then
			return "Confirm the sign-off checkpoint at the workstation."
		end
		return string.format("Keep the workstation powered: emergency sign-off %d%%", math.floor((if s then s.progress else 0) * 100))
	elseif phase == "ClockOut" then
		return "Clock out at the lobby TIME CLOCK, then leave through the front door."
	elseif phase == "Ending" then
		return ""
	end
	local docked = Drives.dockDrive()
	if docked and docked.state == "Processing" and docked.job then
		return string.format("Finish SecureErase on %s at the corner workstation (stage %d/%d).", docked.id, docked.job.state.stage, docked.job.state.stages)
	elseif docked then
		return "Sit at the corner workstation and start SecureErase on " .. docked.id .. "."
	end
	local staged, carried, installed = 0, 0, 0
	for _, x in Drives.list do
		if x.state == "Staged" then
			staged += 1
		elseif x.state == "Carried" then
			carried += 1
		elseif x.state == "Installed" then
			installed += 1
		end
	end
	if carried > 0 then
		return "Bring the drive to the corner workstation DOCK (or stage it on the rack)."
	elseif staged > 0 then
		return "Take a staged drive from the rack and connect it to the workstation dock."
	elseif installed > 0 then
		return string.format("Shut down a desk PC and remove its hard drive (%d left in the desks).", installed)
	end
	return "Keep the shift together."
end

function Story.init()
	GameState.providers.objective = objective
	Drives.Erased:Connect(function(_d, count)
		local frags = GameState.data.fragments
		if not table.find(frags, count) and Dialogue.FRAGMENTS[count] then
			table.insert(frags, count)
			GameState.fx("Fragment", { index = count })
			GameState.markDirty()
		end
		setDread(count)
		if count < Config.DRIVE_COUNT then
			Checkpoints.save(string.format("%d of %d drives erased", count, Config.DRIVE_COUNT))
			task.delay(5, function()
				local line = Dialogue.BOSS_PROGRESS[count]
				if line and GameState.phase == "Work" then
					GameState.bossMessage(line, "story")
				end
			end)
		end
	end)
	Checkpoints.Restored:Connect(function()
		setDread(GameState.data.erased)
	end)
	GameState.RoundReset:Connect(function()
		setDread(0)
		task.spawn(briefing)
	end)
end

function Story.start()
	setDread(0)
	task.wait(2)
	briefing()
end

return Story
