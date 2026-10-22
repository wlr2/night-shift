# Presentation pass: status and handoff

Branch: `claude/presentation-pass`. The first part was made in Claude Code cloud without Studio. The map cleanup
and the Studio checks below were done locally through the Studio MCP.

## Done (static + headless verified)

| Area | Files | What changed |
|---|---|---|
| Foundation | `src/shared/Fonts.luau`, `src/client/Ui/UiKit.luau`, `src/client/Ui/Cursor.luau`, `docs/ART_DIRECTION.md` | Font families (Silkscreen `12187371840`, verified as Roblox FontFamily with Regular+Bold; Ubuntu, Inconsolata and Merriweather through `Enum.Font`), type roles, spacing, palette tokens, cursor ownership |
| Local revision ported | `MapBuilder`, `Layout`, `Atmosphere`, `WorkstationCamera`, `PromptUi`, `src/art` | The preserved `studio/local-working-tree` presentation work (clean desks, trim, curtains, fewer desk props, palette) merged into `src/`. Art regenerated from the release assets |
| Lighting | `Atmosphere.luau`, `Effects.luau` | Palette-exact ambient (#353F46) and outdoor (#778B96), bloom 0.22/20/2.0, low global fog plus client fog cards **outside** the building only, subtle dread, readable blackouts |
| First person | `WorkstationCamera.luau`, `default.project.json` | `LockFirstPerson`, shift-lock off. Seated camera frees the cursor through `Cursor`. Every exit path (leave, B, jump, death, respawn, kick, menu) restores locked first person |
| Desktop UI | `Desktop.luau`, `UiKit.luau` | Older-Windows desktop: cream bevels, charcoal title bars, Silkscreen titles and tray, Inconsolata listings, Merriweather fragments, square corners, viewport scaling |
| HUD | `Hud.luau`, `Pings.luau` | Compact square dark plates, type roles, centre dot, keycap hints, threat cues not colour-only |
| Minigames | `src/client/Views/*` | Matching style; states not colour-only; text ≥ 13 px at 1366×768 and up |
| E prompt | `PromptUi.luau`, `Prompts.luau`, prompt strings | Every prompt `Style = Custom`. One card (keycap + action + object + hold bar), look-based targeting; only the shown prompt can fire. Labels: Collect drive / Dock drive / Sit down … |
| Fixes | `ArtController.luau` | `CreateEditableMesh` wrapped in pcall |

Checks (all clean): `luau-lsp` strict in two passes (with and without the
sourcemap), selene, `tools/check_ui_props.py`, `tools/check_presentation.py`,
the rojo build, and `bash tools/smoke/run.sh` (15/15 scenarios pass).

## Map cleanup (done, local session with Studio MCP)

Measured with `bash tools/audit/run.sh --label after --baseline before-local`
(see `docs/presentation/layout-audit-after.md`, `plan-after.png`).

| Metric | before | after |
|---|---|---|
| Props into walls / glass / ceiling | 20 | 0 |
| Props sunk below floor or desk | 13 | 0 |
| Camera-clip props | 4 | 0 |
| Meshes rendering far from their anchor | 20 | 0 |
| Mesh-confirmed prop overlaps (deepest) | 21 (1.75) | 4 (0.13, partitions touching desk edges) |
| Chairs not facing their desk | 6 | 0 |
| Targets reachable | 22/22 | 22/22 |

- `convert_assets.py`: `recenter` for every `urban__*` model; ceiling uses the clean speckled `horror_wall_03`.
- `MapBuilder`: chair `ART_YAW`; automatic ground lift for vertically centred models; collision on hall, kitchen and extinguisher panels; removed armchair, second workstation PC, NO SMOKING sign, duplicate open breaker panel, hall ducts and pipes, alley trash pile.
- SmoothPlastic glass, muted emergency red, softer fluorescent panels with a ceiling spill light, desaturated status greens, muted dumpster.
- Remaining by design: the rear door is 2.8 studs wide (Layout), the kitchen bin is a trash asset because the trash task needs it.

## Verified live in Studio (MCP, Play Solo, 1174x753 viewport)

Sources were synced into the open `NightShift.rbxlx` with `tools/devsync`.
- Server and client start with no errors or warnings in the log.
- First person: `LockFirstPerson`, mouse `LockCenter`, cursor hidden, zoom 0.5.
- E prompt: Roblox's default prompt UI never showed; one custom card with an E keycap "Sit down" plus an F row "Dock drive"; looking at the dock promotes "Dock drive".
- Sit with a real E keypress: desktop opens, Scriptable camera, cursor free and visible. A real mouse click opened Procedures.txt. Space leaves and restores locked first person.
- Caught while seated (figure from DoorUnlatch): checkpoint restore returned to locked first person with a hidden cursor.
- Power failure: readable with muted emergency light. Alley shows cold blue-grey fog.
- Fixed after Studio screenshots: HUD threat plates grew down the whole screen (scale-height badge inside an AutomaticSize parent), charcoal ceiling, blurry DOCK label, upside-down OUT TRAY label, saturated green door light flooding the hall.

Not verified in Studio: multi-client co-op, gamepad, touch, phone-size viewports (headless smoke only), every minigame.

## Tools added

- `tools/audit/`: headless Lune layout audit. It runs the real MapBuilder
  and reports overlaps, camera clip, reachability and clutter, with plan
  PNGs and approximate offline renders.
- `tools/smoke/`: headless Lune UI smoke harness. It runs the real client
  controllers on real Lune Instances.
- `tools/check_ui_props.py`, `tools/check_presentation.py`: static checks.

## Then

Run the Studio checklist, then the broader bug-fixing pass (deferred until
the presentation is confirmed). Smoke harness warnings to look at: the
desktop briefly reopens if an active Session payload arrives after standing,
and desktop text is 10.8 px on a 667×375 phone.
