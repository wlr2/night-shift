# NIGHT SHIFT: DATA PURGE

**GitHub / Claude cloud:** start with [CLAUDE.md](CLAUDE.md) and the user's [next-session presentation requests](docs/NEXT_SESSION.md). This checkout includes a verified export of all 195 scripts from `NightShift.rbxlx`, its native Studio snapshot, and the separate loose working revision under `studio/local-working-tree/`.

The complete supplied asset library is available from the [asset release](https://github.com/wlr2/night-shift/releases/tag/nightshift-assets-v1). Catalogs and previews are in [assets/context](assets/context); `python tools/fetch_assets.py --key MODEL_KEY` fetches only the selected files. See [assets/README.md](assets/README.md). The built-in art in `src/art` already supports rebuilding the current game without downloading the entire library. Claude cloud does not need Studio MCP to edit and build this repository, but actual Studio playtesting must still happen locally.

Cooperative (1–4 players) psychological-horror Roblox game. An overnight crew pulls
six hard drives from a cramped office, docks them at the corner workstation and wipes
them through six different SecureErase minigames — while the building, the boss and
the figure in the alley make that harder. Finish the queue, cancel the purge that
lists *your own* records, run the emergency sign-off and clock out.

Everything (office, props, lighting, desktop OS, minigames, NPC, story) is built from
code at runtime. The low-poly art comes from your NightShiftAssets library, converted
to Luau data — no uploads or asset IDs are needed to play.

- **Play it:** open `build/NightShift.rbxlx` in Roblox Studio and press Play
  (see [SETUP_WINDOWS.md](SETUP_WINDOWS.md) for rebuilding, Rojo sync and audio).
- **Length:** ~15–25 minutes per shift, then a fresh, re-randomized shift starts.

## How to play

| Goal | How |
| --- | --- |
| Get a drive | Walk to a desk PC, **E** "Shut down PC", **E** again "Remove drive" |
| Stage / dock | **F** at the drive rack (next to the corner desk) or at the workstation dock |
| Erase | **E** "Use workstation" → desktop opens → START SECURE ERASE → solve the stages |
| Leave the PC | **Space**, gamepad **B**, or the red LEAVE COMPUTER button (progress is kept) |
| Power cut | Reset the tripped breaker(s) at the panel in the utility hall |
| Rear door open | Close & latch it (end of the utility hall) before the figure walks in |
| Teammate caught | Hold **E** on them ("Help up") |
| Ping | **G** / gamepad **Y** / on-screen button |

The desktop works with mouse, touch and gamepad (D-pad/thumbstick selection, **A** to
click, **B** to leave). No typing is ever required.

## What's in the game

- **Office** (`MapBuilder`): seven squeezed-together desks (six source PCs + the corner
  workstation that faces the wall), drive rack, kitchenette, lobby with time clock,
  utility hall with labelled breakers, rear service door, short alley with dumpster,
  rainy street outside the windows. Warm desk lamps, cold fluorescents, battery
  emergency lights, rain, film grain, muted colour grade.
- **Assets used:** 115 models converted from your library; 113 placed in the map
  (desks, chairs, CRTs, towers, keyboards, lamps, mugs, papers, cabinets, partitions,
  couches, coffee machine, water cooler, fridge, rack, breaker/thermostat/heater
  panels, signs, pipes, ducts, dumpster, bins, trash bags, hoarding, street lights,
  three characters…), plus 16 surface textures (SBS horror walls/floors/ceiling,
  office carpet). Character_04 is the figure; Character_01/05 are the missing crew.
- **Drives** (`Drives`): explicit server state machine
  `Installed → Carried → Staged → Docked → Processing → Erased`, recovery rack,
  watchdog for lost/out-of-map drives, one item per player.
- **Workstation** (`Workstation`): one server-owned session; only the seated operator
  of the current session id may act; stale ids rejected; stand/death/disconnect/caught
  ends the session; the next operator resumes the saved puzzle.
- **Six minigames** (`server/Minigames`, one shared interface): File Sorting, Sector
  Repair, Signal Routing, Checksum Matching, Memory Sequence, Process Cleanup.
  Randomized per drive, assigned without repetition, 2 stages solo / 3 co-op, small
  local setbacks, 3-level hint system. The server validates every semantic action;
  there is no "complete" message.
- **Event director** (`EventDirector` + `server/Events`): weighted eligible events with
  cooldowns, repeat penalty, conflict rules, learned-mechanic first-time leniency,
  recovery windows, relief after tension, urgent cap (solo 1 / ≤2 players 1 / 3–4
  players 2) and finale caps. Events: Door Unlatches, Power Failure, Phantom Window,
  Boss Request (trash → Alley Encounter, thermostat, printout), False Instruction
  (reject by citing Procedures.txt), Harmless Disturbances.
- **Story** (`Story`, `shared/Dialogue`): six fragments revealed in fixed order by
  erased count, boss reactions, growing dread. Finale (`Finale`): Final Purge queue
  with the players' names → cancel → Emergency Sign-Off (finite, pauses without
  power, operator confirms milestones) → time clock → escape → ending → new shift.
- **Failure** (`PlayerStatus`, `Checkpoints`): caught = downed, teammate rescue;
  solo/team wipe restores the last checkpoint (after each drive, before the finale,
  each sign-off milestone) with all events cleared and a recovery window.

## Project layout

```text
default.project.json   Rojo project (ReplicatedStorage.Shared/ArtData, ServerScriptService.Server, StarterPlayerScripts.Client)
src/shared             Config (all tunables), Types, Net (remote list), Layout (map coords), Dialogue, Util
src/server             init.server.luau + Systems/ (one module per system), Minigames/, Events/, Util/ (Guard, Prompts)
src/client             init.client.luau + Controllers/ (State, ArtController, Desktop, Hud, Atmosphere, Effects, Pings, WorkstationCamera), Views/ (6 minigame UIs), Ui/
src/art                GENERATED by tools/convert_assets.py (mesh + texture data). Do not edit by hand.
tools/                 convert_assets.py, make_audio.py, check.sh, devsync.*, tests/MinigameSpecs.luau, qa/QAClient.luau
build/NightShift.rbxlx Built place file
```

Tunables (event weights, cooldowns, grace times, stage counts, threat speeds, sign-off
length, sounds) are all in `src/shared/Config.luau`; all text is in
`src/shared/Dialogue.luau`.

## Testing that was actually done

Static: `luau-lsp analyze` (strict mode, Roblox definitions) — 0 errors; `selene` — 0 errors.

Unit (Studio, pure logic): `tools/tests/MinigameSpecs.luau` — 6 games × 150 seeds:
every layout solvable, wrong/junk actions never complete a job, completion only after
the final stage and only once, mistakes counted; 50 rounds of game assignment always
6 distinct. **All passed.**

Live in Studio (Play Solo, through real ProximityPrompts, remotes and GUI clicks):
desk PC shut-down/removal, docking, sitting, desktop + camera, START, real FileSort
clicks validated by the server, full drive erase → fragment window → boss reply →
checkpoint; Leave restores camera/mouse/movement; power failure mid-puzzle (actions
rejected, overlay shown, state kept) → breaker reset → resume at the same step;
operator stands → re-sits → new session id resumes the saved puzzle; stale session id
rejected; carrier death and leaving the map both return the drive to the rack; rack
stage/take; door unlatch → grace → figure approach → entry → hunt → catch → solo
checkpoint restore; alley encounter (trash → dumpster → head start → chase → escape
inside); false instruction rejected with procedure citation; phantom window display;
6/6 → Final Purge (player's own record listed) → cancel → sign-off → power cut pauses
sign-off → milestone confirm → clock-out → finale pursuit → front door → escape →
ending → automatic new round; director soak (varied events with recovery gaps).
Simulated second actor (Studio QA harness, server logic only): same-frame double
pickup (exactly one wins), non-operator desktop actions rejected.

## Known limitations / still to verify in Studio

- **Real multi-client testing was not possible from my tools** (Studio's
  Clients-and-Servers launcher was not reachable). Two-player behaviour was checked
  with a simulated server-side actor only. Please run *Test → Clients and Servers*
  with 2–4 players to confirm replication, prompts per client, rescue, late join,
  disconnect mid-carry/mid-session and urgent-cap changes when players leave.
- **EditableMesh/EditableImage**: the art (and wall/floor textures) are built on each
  client with these APIs. Studio limits a client to 8 EditableMeshes (the game uses
  6). For a *published* experience, Roblox gates these APIs (experience/creator
  settings and eligibility can change) — check the current EditableMesh docs before
  publishing. Without them, gameplay still works but props and surface textures
  will be invisible. The production-grade alternative is importing the same FBX/GLB
  files with Studio's 3D Importer.
- **Audio** needs uploaded asset IDs (Roblox cannot play local files). Until you
  upload `audio-upload/*.wav` (generated by `tools/make_audio.py`) and paste the IDs
  into `Config.SOUNDS`, only a few Studio built-in sounds play; some of those may be
  missing in the live client.
- Phone screens: the desktop fits on a 667×375 phone without clipping, but text is
  small (~55% scale). Tablet/PC is the comfortable target.
- The figure is a static (non-animated) mesh gliding on a humanoid controller; the
  supplied character rigs only include pose-length clips.
- Fixture flicker is a client colour-grade effect, not per-light state.
