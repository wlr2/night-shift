--!strict
-- Team checkpoints: saved after every erased drive, before the finale and at
-- each sign-off milestone. Restoring clears every active event, resets power
-- and doors, revives and respawns the team and grants a recovery window.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Types = require(ReplicatedStorage.Shared.Types)
local GameState = require(script.Parent.GameState)
local Drives = require(script.Parent.Drives)
local Power = require(script.Parent.Power)
local Doors = require(script.Parent.Doors)
local Workstation = require(script.Parent.Workstation)
local PlayerStatus = require(script.Parent.PlayerStatus)

local Checkpoints = {}

-- Fired before state is restored; systems with transient state (events,
-- threat, finale timers) clean themselves up here.
Checkpoints.Restoring = Signal.new() :: Signal.Signal<any>
Checkpoints.Restored = Signal.new() :: Signal.Signal<any>

export type Checkpoint = {
	label: string,
	phase: Types.Phase,
	drives: { Drives.SavedDrive },
	fragments: { number },
	extra: { [string]: any },
}

local latest: Checkpoint? = nil
local restoring = false

-- `extra` lets the finale store its own progress (purge, sign-off).
function Checkpoints.save(label: string, extra: { [string]: any }?)
	latest = {
		label = label,
		-- the briefing is a one-off intro: restoring always resumes work
		phase = if GameState.phase == "Briefing" then "Work" else GameState.phase :: Types.Phase,
		drives = Drives.serialize(),
		fragments = table.clone(GameState.data.fragments),
		extra = extra or {},
	}
	GameState.data.checkpoints += 1
	GameState.markDirty()
	GameState.fx("CheckpointSaved", { label = label })
end

function Checkpoints.latest(): Checkpoint?
	return latest
end

function Checkpoints.isRestoring(): boolean
	return restoring
end

function Checkpoints.restore(reason: string)
	if restoring then
		return
	end
	restoring = true
	GameState.fx("Restore", { reason = reason })
	task.wait(1.2) -- let the fade cover the reset
	local cp = latest -- read after the fade so nothing saved during it is lost
	Checkpoints.Restoring:Fire(cp)
	local op = Workstation.operator()
	if op then
		Workstation.kick(op, "restore")
	end
	GameState.clearThreats()
	Power.resetAll()
	Doors.set("Latched")
	if cp then
		Drives.restore(cp.drives)
		GameState.data.fragments = table.clone(cp.fragments)
		GameState.setPhase(cp.phase)
	end
	PlayerStatus.respawnAll()
	GameState.notify(nil, "Checkpoint restored: " .. (if cp then cp.label else "start of shift") .. ".", "info")
	GameState.markDirty()
	restoring = false
	Checkpoints.Restored:Fire(cp)
end

function Checkpoints.init()
	PlayerStatus.TeamWiped:Connect(function(reason)
		Checkpoints.restore(reason)
	end)
	GameState.RoundReset:Connect(function()
		latest = nil
		task.delay(1.5, function()
			Checkpoints.save("start of shift")
			GameState.data.checkpoints = 0
		end)
	end)
end

function Checkpoints.start()
	-- the start of the shift is the first checkpoint
	task.wait(1)
	Checkpoints.save("start of shift")
	GameState.data.checkpoints = 0
end

return Checkpoints
