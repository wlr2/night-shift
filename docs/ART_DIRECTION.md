# Art direction: presentation pass

The reference for every presentation change. The user's brief is in
`docs/NEXT_SESSION.md`; this file turns it into concrete rules.

## Intent

A small, believable, **maintained** office after hours. Cozy interior light
surrounded by cold, quiet darkness. Silent Hill 2 informs the muted colour,
fog, restraint and stillness. It does **not** mean grime, decay or industrial
clutter. The office is occupied and cared for. Its age shows in modest wear,
not dirt. Dread comes from silence, cold light outside the glass and subtle
disturbances, not from a filthy room.

## Palette

| Token | Hex | RGB | Use |
|---|---|---|---|
| fog | `#A8BAC3` | 168,186,195 | Outdoor fog, rain, exterior street lights, window glass tint |
| slate | `#778B96` | 119,139,150 | Cold ambient light (OutdoorAmbient, moonlight through windows) |
| charcoal | `#353F46` | 53,63,70 | Shadow tone: Lighting.Ambient floor, UI title bars. Never the paint colour of a wall |
| burgundy | `#60494D` | 96,73,77 | Faded carpet, curtains, an occasional upholstery accent |
| cream | `#B7B09C` | 183,176,156 | Painted trim, skirting, old plastic (monitors, docks, time clock), desktop window faces |
| amber | `#C8A66B` | 200,166,107 | Localised practical light only: desk lamps, hall bulbs, workstation lamp, lit windows across the street |

Rules:

- Apply the palette with restraint. Adapt it to each material instead of
  tinting everything equally.
- Interior walls stay light, readable painted plaster or clean wallpaper
  (≈ 205-226 RGB albedo). Shadow comes from lighting, not paint.
- Cold fog and slate light belong outside and at the windows. The office
  interior must stay clear and readable: no visible indoor haze at 0-45 studs.
- Amber is used in small pools around practical fixtures only.
- Avoid heavy bloom (Intensity ≤ 0.3, Threshold ≥ 1.8), crushed blacks
  (Ambient never below ~40/255 per channel indoors), saturated light colours
  and fog that hides the workspace.

## Layout and props

- 6–8 tightly arranged desks with the main workstation in a corner. Desks
  may sit close together, but furniture never overlaps and props never
  intersect each other or walls.
- Keep clear walking routes at least 3.5 studs wide between desk rows, from
  every door, and to every interactable (towers, dock, rack, breakers, door,
  trash, time clock). Keep 2.5 studs of free floor behind each chair.
- Give each desk 1–3 purposeful objects: a mug, papers, a binder or a lamp.
  Leave some surfaces nearly empty. Vary the choices between desks.
- Use clean asset variants. Remove weathered and rusty props, trash piles
  indoors, boarded windows and hazard signs from the interior. The alley may
  keep a dumpster and a few bags, but not a landfill.
- Large props that a player can walk into need collision that covers their
  visual bounds, so the first-person camera never enters a mesh.

## Typography

Families (all verified in Roblox):

- **Silkscreen** `rbxassetid://12187371840`, a Roblox FontFamily with
  Regular and Bold. Use it for short retro computer text only: window
  titles, system status lines, labels on physical objects (DOCK, BREAKERS),
  keycaps, taskbar clock, ≤ ~28 characters. Never use it for sentences,
  dialogue, instructions or body copy.
- **Ubuntu**, via `Font.fromEnum(Enum.Font.Ubuntu)`: dialogue, instructions,
  buttons, toasts and any sentence.
- **Inconsolata**, via `Enum.Font.Code`: file listings, checksums, tables
  and logs.
- **Merriweather**, via `Enum.Font.Merriweather`: recovered memos and story
  fragments only, like the letters in SH2.

Use the roles in `UiKit.TYPE` (`display`, `title`, `key`, `heading`,
`body`, `dialogue`, `button`, `caption`, `mono`, `letter`) through
`UiKit.text(role, props)`. Readable text never goes below 13 px at
UIScale 1. Use `UITextSizeConstraint` on scaled text. Do not use
`Enum.Font.Arcade`, `Arial` or `SourceSans` anywhere.

## UI surfaces

**Desktop** (seated workstation): a coherent older Windows-like OS.

- Cream/grey bevelled faces (`UiKit.C.face`), 2 px bevels, square corners.
- Charcoal-blue title bars (`title1` → `title2`) with Silkscreen titles and
  a small square close button.
- The desktop background is a muted slate-teal (`UiKit.C.desktop`).
- The taskbar is a cream face with a sunken clock well.
- Selection highlight uses `select` (charcoal blue) with white text.
  Gamepad selection tints toward amber.
- Spacing uses the `UiKit.SPACE` steps: 8 px window padding, 4/8 px gaps.
- Buttons: Ubuntu Bold 16, bevelled, with hover, pressed, disabled and
  selected states.

**HUD** (walking): dark translucent plates (`UiKit.C.hud`, 0.2–0.3
transparency) with a 1 px `hudLine` stroke, `hudText`/`hudDim` text and
8–12 px padding. Square corners: **no UICorner anywhere** (small 2 px
radii are tolerated only if they already exist on tiny elements). Keep
panels compact and out of the centre of the screen. A small centre dot
marks the first-person aim point while walking.

**Interaction prompt**: one custom card. A small cream keycap (Silkscreen
letter) sits beside a specific action label in Ubuntu Bold, with an
optional object line in Ubuntu caption. A thin amber hold bar appears for
hold prompts. Only the single most relevant nearby target is shown, so
prompts never overlap. It hides while the desktop is open or the player is
downed.

**Physical labels** (SurfaceGuis on the dock, breakers, time clock and
monitor): Silkscreen, dark text on cream, or soft green or amber phosphor on
dark screens.

## First person

- Gameplay is locked to first person (`CameraMode.LockFirstPerson`).
  The cursor is locked and hidden while walking.
- Sitting at the workstation uses a scripted camera that looks at the
  monitor. The cursor is freed through `Ui/Cursor` (`Cursor.request(reason,
  true)`). Leaving, death, a stand, a downed state or a server-ended session
  restores first-person control at once.
- The camera must not show the inside of the player's head or clip into
  nearby furniture.
