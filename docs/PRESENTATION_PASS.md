# Presentation pass: status and handoff

Branch: `claude/presentation-pass`. This was made in Claude Code cloud **without
Roblox Studio**: no Studio MCP is reachable from a cloud container. Nothing
here has been playtested in Studio. Use `docs/STUDIO_TEST_CHECKLIST.md`
locally.

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

## Not done: map cleanup (next step)

The map agent was stopped by the usage limit before editing `MapBuilder`. The
headless audit (`bash tools/audit/run.sh --label current`; see
`docs/presentation/layout-audit-current.md` and `plan-current.png`) lists the
remaining work:

1. **Off-centre art (bug from before this pass):** `urban__*` models and
   `concrete_retro_bollard_light` keep their source-scene origins and render
   49–121 studs from their anchors. Examples: the alley trash bag renders
   inside the office, and the kitchen bin and dumpster render far from their
   prompts. Fix it in `tools/convert_assets.py` (re-centre the origin, or set
   `targetHeight`), then regenerate with
   `python3 tools/fetch_assets.py --key …` and
   `python3 tools/convert_assets.py --library assets/library --out src/art`.
2. **Chairs face backwards:** add `ART_YAW` 180 for
   office_chair_black/grey/blue/black_alt and about −90 for grey_alt, and lift
   them by about 0.55 (they sit below the floor).
3. Overlaps: lounge armchair vs bookcase, whiteboard and door; fridge inside
   the counter; the coffee machine is too big (scale ~0.23); couch, wall clock
   and desktop_brick go into walls.
4. Camera clip: the hall panels, breaker panel, kitchen panel and fire
   extinguisher need collision or must sit flush in the wall.
5. Sunk props: door_brown_a (+3.3), metal rack (+1.34), yellow posts (+2.4),
   paper sheet on desk 6 (+0.5).
6. Materials: switch window glass from `Glass` to `SmoothPlastic`
   (Roblox's Glass hides the exterior fog behind it). Use a muted emergency
   red (196,110,96). Use cleaner ceiling tiles (the current ones look dark and
   grimy in `view-current-*.png`). Shrink or remove the red NO SMOKING sign.

Routes are already fine: all 22 interactables are reachable, and every
route except the rear door is ≥ 3.5 studs wide.

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
