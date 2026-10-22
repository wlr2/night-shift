--!strict
-- All story text: boss messages, recovered fragments, procedures and the
-- ending. Original fiction. Kept short; the desktop and the building carry
-- the story. Fragment order is fixed by the number of erased drives, never by
-- which physical drive was chosen.

local Dialogue = {}

Dialogue.COMPANY = "Marlowe Records & Retention"
Dialogue.BOSS = "R. Kessler"

Dialogue.INTRO = {
	"Evening. Six old archive drives tonight. Pull them from the desks, dock them at the corner PC, run SecureErase.",
	"Routine disposal of obsolete company data. Nothing on them matters any more.",
	"The building is old. Doors stick, breakers trip. Handle it and keep the queue moving.",
}

-- Shown in order: fragment[n] is revealed when the nth drive is erased.
export type Fragment = { title: string, kind: string, body: string }

Dialogue.FRAGMENTS = {
	{
		title = "MAINT-0311.txt",
		kind = "Maintenance note",
		body = "Rear service door latch replaced again. Third time since the night of Nov 3rd. Whoever keeps forcing it is doing it from the OUTSIDE. - Facilities",
	},
	{
		title = "ROSTER_NIGHT_2003.xls",
		kind = "Employee record",
		body = "NIGHT CREW 03-NOV-2003: D. MERRIN (lead), A. OSEI, P. LIND, J. RUIZ.\nStatus field for all four: PENDING PURGE.",
	},
	{
		title = "SECLOG_0312.log",
		kind = "Incident report",
		body = "03:12 time clock shows four employees clocked IN. None clocked OUT.\n04:40 four cars still in the lot.\n06:05 cars towed on instruction of R. Kessler.",
	},
	{
		title = "merrin_draft.msg",
		kind = "Unsent message",
		body = "Kessler wants the drives wiped tonight. I read what's on them. I'm not doing it. If anyone finds this: don't let him finish the queue. - Dale",
	},
	{
		title = "FAC-UNIFORM.memo",
		kind = "Facilities memo",
		body = "Brown night-crew jackets were discontinued in 1999. Staff report a man in one standing in the alley after midnight. Do not engage. Keep the rear door latched.",
	},
	{
		title = "KESSLER_PURGE_PLAN.doc",
		kind = "Internal memo",
		body = "Once the archive is clean there is no record of the 2003 crew. Schedule FINAL PURGE automatically at end of queue. Include tonight's staff records. No loose ends.",
	},
}

-- Boss reactions keyed by erased count (progression, not time).
Dialogue.BOSS_PROGRESS = {
	[1] = "Good. One down. Keep going.",
	[2] = "Don't open the files. Just erase them.",
	[3] = "Halfway. Ignore anything you think you read.",
	[4] = "Faster, please. The queue needs to finish before morning.",
	[5] = "One left. You're doing exactly what I need.",
	[6] = "That's all of them. The system will take it from here. Stay at your desks.",
}

Dialogue.PROCEDURES = {
	"1. SecureErase verification stages may never be skipped.",
	"2. Erased drives stay on the rack for morning collection.",
	"3. Rear service door stays LATCHED after 22:00. No overnight deliveries.",
	"4. Reset tripped breakers at the utility hall panel only.",
	"5. Never switch MAIN off while an erase job is active.",
}

-- False instructions: each contradicts a numbered procedure.
export type FalseInstruction = { id: string, text: string, procedure: number, reply: string }
Dialogue.FALSE = {
	{ id = "door", text = "A courier is coming to the back. Leave the rear door unlatched for him.", procedure = 3, reply = "...Fine. Keep it shut, then." },
	{ id = "main", text = "Breaker 2 is overheating. Switch MAIN off for a couple of minutes.", procedure = 5, reply = "Hm. Suit yourself." },
	{ id = "force", text = "Skip verification on this drive. Click FORCE ERASE, it's faster.", procedure = 1, reply = "You read the binder. Of course you did." },
	{ id = "dumpster", text = "Take the erased drives out to the dumpster now.", procedure = 2, reply = "Leave them, then. It doesn't matter." },
}

Dialogue.BOSS_REQUESTS = {
	trash = "Kitchen bin is overflowing. Take the bag out to the dumpster in the alley.",
	thermostat = "Check the thermostat in the utility hall and confirm the reading.",
	printout = "The printer by the south wall has a report for me. Put it in the OUT TRAY on the corner desk.",
}

Dialogue.REQUEST_DONE = { "Thanks.", "Good.", "Noted." }
Dialogue.REQUEST_LATE = "Never mind. I'll remember that."

Dialogue.FINAL_PURGE = "AUTOMATIC FINAL PURGE QUEUED: EMPLOYEE RECORDS. Executing at end of countdown."
Dialogue.FINAL_PURGE_BOSS = "Don't touch the purge queue. It's mandatory."
Dialogue.SIGNOFF_START = "EMERGENCY SIGN-OFF: writing tonight's timesheets to the off-site backup. Keep the workstation powered."
Dialogue.SIGNOFF_BOSS = "Stop that. Step away from the computer."
Dialogue.CLOCKOUT = "SIGN-OFF COMPLETE. Your records are safe off-site. The time clock is unlocked. Clock out and leave."

Dialogue.ENDING = {
	title = "CLOCKED OUT",
	lines = {
		"The rain had stopped by the time you reached the street.",
		"Behind the glass, the lobby time clock printed one more card.",
		"D. MERRIN - OUT - 05:58.",
		"Somewhere off-site, a backup drive holds two night crews. Neither of them was erased.",
	},
}

Dialogue.HARMLESS = {
	monitor = { "ARE YOU STILL HERE?", "D.MERRIN LOGGED IN", "03:12", "DON'T FINISH THE QUEUE" },
}

return Dialogue
