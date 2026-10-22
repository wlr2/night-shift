--!strict
-- Shared type definitions. Everything that crosses the client/server
-- boundary is described here so both sides agree by construction.
-- Types document intent only: the server still validates every payload.

export type Phase = "Briefing" | "Work" | "FinalPurge" | "SignOff" | "ClockOut" | "Ending"

export type DriveState = "Installed" | "Carried" | "Staged" | "Docked" | "Processing" | "Erased"

export type DoorState = "Latched" | "Ajar" | "Open"

export type DriveSnapshot = {
	id: string,
	name: string,
	state: DriveState,
	game: string?,
	gameTitle: string?,
	progress: number, -- 0..1 of the deletion job
	stage: number,
	stages: number,
	carrier: string?,
	desk: number,
}

export type BossMessage = {
	id: number,
	from: string,
	text: string,
	kind: string, -- "info" | "request" | "false" | "story" | "system"
	choices: { string }?,
	answered: string?,
	t: number,
}

export type ThreatInfo = {
	id: string,
	label: string,
	urgent: boolean,
	where: string?,
}

export type Snapshot = {
	phase: Phase,
	erased: number,
	total: number,
	nightMinutes: number,
	power: { main: boolean, lights: boolean, workstation: boolean, warning: boolean },
	door: DoorState,
	threats: { ThreatInfo },
	drives: { DriveSnapshot },
	dock: string?,
	operator: string?,
	boss: { BossMessage },
	fragments: { number },
	purge: { { name: string, cancelled: boolean, locked: boolean, userId: number? } }?,
	purgeDeadline: number?,
	signOff: { progress: number, awaiting: boolean, paused: boolean }?,
	clockedOut: { string },
	frontDoorOpen: boolean,
	objective: string,
	checkpoints: number,
	serverTime: number,
	soloMode: boolean,
}

-- Per-minigame client projection. Each view module knows its own shape.
export type MinigameView = { [string]: any }

export type SessionPayload = {
	active: boolean,
	sessionId: number,
	driveId: string?,
	driveName: string?,
	game: string?,
	title: string?,
	instructions: string?,
	stage: number,
	stages: number,
	progress: number,
	view: MinigameView?,
	feedback: string?,
	feedbackKind: string?, -- "good" | "bad" | "info"
	hint: string?,
	transitioning: boolean,
	phantom: { id: number, x: number, y: number, first: boolean }?,
	reason: string?,
}

return nil
