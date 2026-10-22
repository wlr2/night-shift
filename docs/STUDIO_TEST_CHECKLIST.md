# Local Studio checklist: presentation pass

This pass was made in Claude Code cloud **without Roblox Studio access**. No
Studio MCP was reachable from the cloud container. Everything below was
checked only statically or headlessly (see `docs/PRESENTATION_PASS.md`).
Run through this list in Studio and note anything that looks or feels wrong.

## 0. Open the build

1. `git fetch && git checkout claude/presentation-pass`
2. Open `build/NightShift.rbxlx` in Roblox Studio, or rebuild it first:
   `rojo build default.project.json -o build/NightShift.rbxlx`.
3. Press **Play** (F5). Wait for "clocking in…" to finish. The props are
   baked on the client.
4. Keep the **Output** window open. Any red error from `Client`,
   `Server` or `Prompts` is a bug: copy it.

## 1. Office look (stand still, then walk slowly)

- [ ] The office reads as maintained after hours, not as a storage room:
      light painted walls with cream trim, a subdued burgundy carpet and
      clean desks.
- [ ] Each desk holds only 1–3 objects besides the computer. Some desks
      are nearly bare, and no two desks look identical.
- [ ] Nothing visibly intersects: chairs and desks, monitors and lamps,
      partitions and desks, props and walls, curtains and window frames.
      Look closely at the corner workstation and the drive rack.
- [ ] The interior has no visible haze. Desks at the far end stay crisp.
- [ ] The windows show a cold, pale blue-grey fog and rain outside. The
      street and alley fade into fog.
- [ ] Warm amber light appears only in small pools: a few desk lamps,
      the workstation lamp and the hall bulbs.
- [ ] Blacks are not crushed (shadowed corners still show the wall
      shape). Bloom is subtle, with no glowing halos around fluorescents.
- [ ] Power failure (Cheat `power`, or wait for one): it is tense but you
      can still find the hall and breakers. Emergency light and your dim
      personal light are enough.

QA shortcut from the command bar while playing (client):
`game.ReplicatedStorage.Remotes.Cheat:FireServer("tp", "office")`.
Other targets: `workstation`, `kitchen`, `hall`, `alley`, `lobby`, `rack`.

## 2. Walking routes and clipping

- [ ] Walk from spawn to each of the six desk PCs, the drive rack, the
      workstation chair, the kitchen bin, the hall breakers, the rear
      door, the lobby time clock and the front door. Nothing snags and
      no route needs side-stepping.
- [ ] Between the desk rows, you pass without scraping chairs.
- [ ] Push your face into every tall object (cabinets, fridge, water
      cooler, whiteboard, partitions, bookcase, coffee machine, couch).
      The camera never enters the mesh.
- [ ] Walk along every wall and through every doorway, turning the camera.
      You never see through walls or door frames.
- [ ] Look straight down while walking. You never see the inside of your
      head or hair. Your body may show, which is fine.

## 3. First person, sitting and the mouse

- [ ] Gameplay starts in first person. The mouse is locked and hidden, and
      a small centre dot is visible.
- [ ] Mouse wheel and `I`/`O` cannot zoom out to third person.
- [ ] At the corner workstation, **E "Sit down"** works. The camera moves
      smoothly to the monitor, the cursor appears, and the dot hides.
- [ ] Every desktop control is clickable: Start, windows, close buttons,
      minigame controls and LEAVE COMPUTER.
- [ ] Leaving with **Space**, the red **LEAVE COMPUTER** button, and
      gamepad **B** (if available) returns you to first person at once,
      with the cursor locked and hidden and normal mouse look. Try each.
- [ ] Sit, open the Roblox menu (Esc) and close it. The cursor is still
      free at the desktop. Leave, press Esc and close it. You are back in
      locked first person.
- [ ] Sit, then trigger a power failure. The desktop shows the
      no-power overlay. You can still leave.
- [ ] Die or get caught while seated (Cheat `down` / `hunt`). There is no
      stuck cursor or camera after respawn or restore.
- [ ] With **Test → Clients and Servers** (2 players): one sits while the
      other walks. Each client's cursor and camera are correct, and the
      second player sees "Occupied" on the chair.

## 4. E prompts (custom card)

- [ ] Roblox's default grey prompt bubble never appears anywhere.
- [ ] Near a desk PC the card shows a small **E** keycap and
      **"Shut down PC"**, then after holding, **"Collect drive"** with
      the drive id under it.
- [ ] With a drive, at the dock: an **F** keycap with **"Dock drive"**.
      At the chair: **"Sit down"**. At the rack: **"Stage drive"** /
      **"Take drive"**.
- [ ] With two prompts in reach (dock and chair), you see one card, plus
      at most a smaller second row for the other key. Cards never stack
      or overlap.
- [ ] Turning to look between two nearby targets switches the card to the
      one you face, without flicker.
- [ ] The hold bar fills smoothly on hold prompts and resets if you let go.
- [ ] The card is readable over bright fluorescents and dark corners.
- [ ] It hides while seated, while downed and after escaping.
- [ ] Gamepad: the keycap shows the gamepad button. Touch (Studio device
      emulator): tapping the card triggers it.
- [ ] Breakers, rear door ("Open door" / "Close & latch"), time clock
      ("Clock out"), boss tasks (trash, thermostat, printout) and
      "Help up" on a downed teammate all show the right labels.

## 5. Typography and text boxes

- [ ] Silkscreen (pixel font) appears only on short computer-style text:
      window titles, status words, keycaps, the taskbar clock and physical
      labels (DOCK, BREAKERS, TIME CLOCK). It never appears in sentences.
- [ ] Dialogue, toasts, objectives, instructions and buttons use the
      clean sans (Ubuntu). File lists and checksums use the mono font.
      Story fragments use the serif.
- [ ] If Silkscreen ever renders as a fallback font (the pixels look
      smooth), note it. The asset is Roblox's own font family
      12187371840 and should load.
- [ ] HUD panels (objective, threats, team, toasts) are compact, square
      and consistently padded, and stay out of the screen centre.
- [ ] The desktop reads as one older OS: cream/grey bevelled windows,
      charcoal title bars, a muted wallpaper and a taskbar with a pixel
      clock. There are no rounded mobile-style panels.
- [ ] Minigames match the desktop style. Selected, wrong and right states
      are clear even without colour.

## 6. Screen sizes

Use the Studio **Device** emulator (Test → Device) or resize the window:

- [ ] 1920×1080: comfortable.
- [ ] 1366×768: nothing overlaps or clips.
- [ ] Phone landscape (~667×375): the desktop fits, and body text is
      small but readable. The prompt card and HUD do not cover each other.
- [ ] 2560×1440: text is not tiny.

## 7. Gameplay sanity (presentation must not have changed rules)

- [ ] One full drive: shut down a PC, collect the drive, dock it, sit
      down, erase it and leave. Progress counts.
- [ ] Door unlatch → close & latch, breaker reset, trash run to the
      dumpster, false instruction rejected: all still work.
- [ ] Finale reachable with `Cheat eraseAll` → sign-off → clock out.

Report any failure with what you did, what you saw and any Output errors.
