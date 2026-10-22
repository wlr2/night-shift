--!strict
-- Tunable gameplay values for NIGHT SHIFT: DATA PURGE.
-- NOTE: replicated to clients — nothing secret here. The server never trusts a
-- client-reported value; these numbers only drive server decisions and UI.

local Config = {}

Config.GAME_TITLE = "NIGHT SHIFT: DATA PURGE"
Config.MAX_PLAYERS = 4
Config.DRIVE_COUNT = 6

-- Interaction reach (studs). ProximityPrompts enforce this client-side; the
-- server re-checks with a small tolerance.
Config.REACH = {
	prompt = 10,
	tolerance = 4,
	workstation = 9,
	revive = 9,
}

Config.RATE = {
	-- tokens per second, burst
	desktop = { 12, 20 },
	leave = { 2, 4 },
	ping = { 0.5, 2 },
	cheat = { 5, 10 },
}

-- Time-of-night display: real seconds -> in-game minutes. Purely cosmetic;
-- no event is ever scheduled from this clock.
Config.NIGHT_START_MINUTES = 23 * 60 -- 23:00
Config.GAME_MINUTES_PER_SECOND = 0.33

Config.PHASE = {
	briefingSeconds = 14,
	directorGraceSeconds = 40, -- no events right after the shift starts
	finalPurgeCountdown = { solo = 150, coop = 120 },
	signOffSeconds = { solo = 80, coop = 100 }, -- powered seconds of sign-off
	signOffConfirmAt = { 0.25, 0.5, 0.75 },
	clockOutUnlockAfterFirst = 30, -- front door opens this long after the first clock-out
	endingSeconds = 28,
}

-- Drives: label colours are purely presentational (labels also carry text).
Config.DRIVES = {
	{ id = "HD-1147", name = "ACCOUNTS-ARCHIVE", color = Color3.fromRGB(196, 170, 98) },
	{ id = "HD-2203", name = "PERSONNEL-03", color = Color3.fromRGB(120, 150, 190) },
	{ id = "HD-3318", name = "FACILITIES-LOG", color = Color3.fromRGB(150, 180, 120) },
	{ id = "HD-4402", name = "SECURITY-NIGHT", color = Color3.fromRGB(190, 120, 110) },
	{ id = "HD-5521", name = "CORRESPONDENCE", color = Color3.fromRGB(170, 140, 190) },
	{ id = "HD-6090", name = "LANTERN-BACKUP", color = Color3.fromRGB(200, 200, 190) },
}

Config.DRIVE_RECOVERY_Y = -30 -- drives below this height are recovered
Config.DRIVE_WATCHDOG_SECONDS = 2

-- Minigame tuning. stages = number of short stages per drive.
Config.MINIGAMES = {
	FileSort = { stages = { solo = 2, coop = 3 }, filesPerStage = { 5, 6, 7 } },
	SectorRepair = { stages = { solo = 2, coop = 3 }, sectors = { 4, 5, 6 } },
	SignalRouting = { stages = { solo = 2, coop = 3 }, grid = { { 4, 3 }, { 4, 4 }, { 5, 4 } } },
	Checksum = { stages = { solo = 2, coop = 3 }, matchesPerStage = 3, records = { 4, 5, 6 } },
	MemorySequence = { stages = { solo = 2, coop = 3 }, length = { 3, 4, 5 } },
	ProcessCleanup = { stages = { solo = 2, coop = 3 }, processes = { 5, 6, 7 }, targets = { 2, 3, 3 } },
}
Config.HINT_MISTAKES = { 2, 4, 6 } -- mistakes in a stage that unlock hint levels 1..3
Config.STAGE_TRANSITION_SECONDS = 1.6

-- Event director ----------------------------------------------------------
-- Escalation is driven by erased drives, not by the clock.
Config.DIRECTOR = {
	tickSeconds = 1,
	-- [tier] = {minGap, maxGap} seconds between event rolls
	gaps = {
		early = { 42, 70 },
		mid = { 30, 52 },
		late = { 22, 38 },
		finale = { 14, 24 },
	},
	recoveryAfterUrgent = { early = 26, mid = 20, late = 15, finale = 10 },
	reliefBoostAfterUrgent = 2.4, -- weight multiplier for harmless events after an urgent one
	repeatPenaltyLast = 0.3,
	repeatPenaltyRecent = 0.6,
	historySize = 4,
	nearCompleteUrgentScale = 0.6, -- urgent weight when the active puzzle is almost done
	signOffMaxUrgent = { solo = 3, coop = 4 }, -- hard cap so the finale always finishes
	finalPurgeMaxUrgent = 1,
}

-- Urgent threat cap by active player count.
function Config.urgentCap(activePlayers: number): number
	if activePlayers <= 2 then
		return 1
	end
	return 2
end

function Config.tierFor(erased: number, phase: string): string
	if phase == "SignOff" or phase == "FinalPurge" or phase == "ClockOut" then
		return "finale"
	elseif erased >= 4 then
		return "late"
	elseif erased >= 2 then
		return "mid"
	end
	return "early"
end

Config.EVENTS = {
	DoorUnlatch = {
		weight = 10,
		cooldown = 70,
		minErased = 0,
		-- seconds the door may stay unsecured before the figure starts approaching
		graceFirst = 55,
		grace = { early = 45, mid = 36, late = 28, finale = 24 },
		approachSeconds = 12, -- walk time from alley end to the doorway
	},
	PowerFailure = {
		weight = 9,
		cooldown = 80,
		minErased = 1,
		warningSeconds = 5,
		-- breakers that trip: MAIN only early; later sometimes two
		multiTripChance = { early = 0, mid = 0.25, late = 0.45, finale = 0.5 },
	},
	PhantomWindow = {
		weight = 8,
		cooldown = 55,
		minErased = 1,
		lifetime = 40,
	},
	BossRequest = {
		weight = 5,
		cooldown = 140,
		minErased = 0,
		timeout = 120,
	},
	FalseInstruction = {
		weight = 6,
		cooldown = 120,
		minErased = 2,
		replyWindow = 60,
	},
	Harmless = {
		weight = 9,
		cooldown = 18,
		minErased = 0,
	},
}

Config.THREAT = {
	walkSpeed = 9,
	approachSpeed = 4.2, -- slow, readable walk up the alley (~12 s warning)
	approachPause = 2.5, -- stares from the alley mouth first
	huntSpeed = { solo = 10, coop = 11.5 },
	chaseSpeed = { first = 10.5, normal = 13 },
	huntSeconds = { solo = 16, coop = 26 },
	catchDistance = 3.4,
	headStartSeconds = 2.6,
	clockOutSpeed = 8.5,
}

Config.DOWNED = {
	reviveHold = 2.5,
	soloRestoreDelay = 2.5,
	wipeRestoreDelay = 3.5,
	restoreRecoverySeconds = 30,
}

Config.PING = {
	lifetime = 6,
	maxDistance = 120,
}

-- Optional audio. Roblox requires uploaded audio asset IDs; none are invented
-- here. Upload the clips produced by tools/prepare_audio.py and paste their IDs
-- ("rbxassetid://123...") below. Empty strings fall back to Studio built-ins
-- where one exists, otherwise that sound is silent.
Config.SOUNDS = {
	ambientRoom = "", -- PSX Ambient Pack "Still" excerpt (audio-upload/ambientRoom.wav)
	ambientTense = "", -- PSX Ambient Pack "Distant" excerpt (fades in with dread)
	ambientFinale = "", -- PSX Ambient Pack "Hollow" excerpt (finale only)
	rain = "", -- tools/make_audio.py: rain.wav (original, procedural)
	fanHum = "", -- tools/make_audio.py: fanHum.wav (original, procedural)
	chime = "rbxasset://sounds/electronicpingshort.wav",
	click = "rbxasset://sounds/electronicpingshort.wav",
	breaker = "rbxasset://sounds/action_jump_land.mp3",
	footsteps = "rbxasset://sounds/action_footsteps_plastic.mp3",
	doorSlam = "rbxasset://sounds/action_jump_land.mp3",
	error = "rbxasset://sounds/electronicpingshort.wav",
	knock = "rbxasset://sounds/action_jump_land.mp3",
	phone = "rbxasset://sounds/electronicpingshort.wav",
}

-- Studio-only QA cheats; production servers also allow these user IDs.
Config.DEV_USER_IDS = {} :: { [number]: boolean }

return Config
