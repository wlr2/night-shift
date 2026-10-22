# Headless layout audit

Measures the office layout without Studio: clutter, prop clipping,
first-person camera coverage, walking routes and prompt reachability. It runs
the **real** `src/server/Systems/MapBuilder.luau` under [Lune](https://lune-org.github.io/docs),
dumps every part, art anchor and light, and analyses the result with the
converted meshes in `src/art`.

Everything here is an offline approximation. It catches geometry mistakes
quickly, but it is not a Studio playtest. Confirm anything that matters in
Studio.

## Run it

```sh
bash tools/audit/run.sh                      # audit the working tree as "current"
bash tools/audit/run.sh --label current --views   # plus approximate eye-height renders (~20 s more)
```

Audit another revision, such as the exported Studio baseline:

```sh
mkdir -p /tmp/before
git archive 8dd1dfe src default.project.json | tar -x -C /tmp/before
bash tools/audit/run.sh --label before --src /tmp/before --describe "8dd1dfe (Studio baseline)"
```

Options: `--label NAME`, `--src DIR` (a checkout root or its `src/`),
`--baseline NAME` (compare with `tools/audit/out/NAME.json`; defaults to
`before` when it exists), `--views`, `--describe TEXT`.

Requirements: Lune 0.10.x (`lune` on `PATH`, `LUNE=/path/to/lune`, or
`/root/bin/lune`) and Python 3 with numpy and Pillow. A run takes about 10 s
(about 30 s with `--views`).

Outputs:

| File | Contents |
|---|---|
| `docs/presentation/layout-audit-NAME.md` | Metrics (with a before/after column), ranked issues with coordinates, detail tables |
| `docs/presentation/plan-NAME.png` | Top-down plan: floors, walls, collision, mesh silhouettes, lights, routes, interactables, numbered issues |
| `docs/presentation/view-NAME-N.png` | With `--views`: approximate eye-height renders, captioned as such |
| `tools/audit/out/NAME.json` | Machine-readable results (`metrics`, `issues`, and every table) |
| `tools/audit/out/NAME.dump.json` | Raw harness dump (git-ignored, regenerated each run) |

Issue numbers in the markdown match the numbered badges on the plan. The plan
draws north (-Z) up and +X to the right, with a grid line every 5 studs.

## How it works

`harness.luau` (Lune) mounts the source tree as ModuleScripts exactly as
`default.project.json` does: `src/shared` becomes `ReplicatedStorage.Shared`,
`src/art` becomes `ReplicatedStorage.ArtData`, and `src/server` becomes
`ServerScriptService.Server`. As a result, `require(ReplicatedStorage.Shared.Layout)`
and `script.Parent` resolve to the repository files. The harness loads each
module with `luau.load` in a Roblox-like environment and calls
`MapBuilder.init()`.

- Instances are real Lune instances wrapped in thin proxies, so engine-derived
  members behave like Roblox. These include `BasePart.Position` and
  `Orientation`, `GetPivot` and `PivotTo` on parts and models,
  `GetBoundingBox`, `WaitForChild` (which errors instead of hanging), signals
  and `Clone`. Without the proxies, Lune would silently store a `Position` that
  never moves the part.
- Mocked services: CollectionService (tags on the real instances),
  PhysicsService (collision groups), Players, RunService, TweenService (tweens
  jump to their goal), HttpService and Debris. Other services come from Lune's
  DataModel. `task.spawn` runs inline. `task.defer` and `task.delay` run after
  `init` returns, so delayed placement still appears in the dump.
- A build error, or a Roblox API the harness does not implement, stops the
  run with a traceback and a non-zero exit code. Add missing APIs to `METHODS`,
  `GET`, `SET` or `mockServices` in `harness.luau`. MapBuilder is never edited
  to suit the harness.

`analyze.py` reads the dump (parts, art anchors with `ArtKey`, `ArtScale` and
the anchor CFrame, lights, `MapBuilder.refs`, the `Layout` and
`Config.REACH` values, and the `ArtData.Index` bounds). It also decodes each
model with `artmesh.py`, which matches `ArtController.luau`: int16 vertices
quantised to each part box, atlas UVs and a per-part colour.

## What each metric means

| Section | Method | Flag |
|---|---|---|
| **Prop overlaps** | Oriented bounding boxes (model bounds × ArtScale, posed by the anchor), separating-axis test with penetration depth. Pairs within 0.05 stud are treated as touching. Items resting on a desk or cabinet top, or stored inside storage furniture, count as justified nesting. Shallow vertical contacts (≤ 0.2) are listed separately. Mesh check: both meshes are sampled every 0.1 stud, and when the samples share ≥ 4 voxels of 0.1 stud the surfaces really meet. | Mesh-confirmed overlaps become issues. Box-only overlaps (for example a chair under a desk's knee space) are listed for reference only. |
| **Into structure** | The prop's box is tested against visible structure (walls, glass, ceilings, counters, trim), visible interactive parts and other props' collision proxies. Depth is the deepest sampled mesh point inside that box, so a wall's half thickness (0.5) means the prop goes right through. | Walls, glass and ceilings > 0.1 stud. Wall-mounted props (panels, signs, clocks) may sink up to 0.35 as a flush mount. Trim contacts and other-furniture collision are reported as tables only. |
| **Sunk** | Lowest mesh vertex compared with the surface the anchor stands on (floor or desk top). | > 0.08 stud below. |
| **Mesh offset** | Distance from the model's geometry to its anchor. Some converted models keep their scene position, so the client draws them far from where MapBuilder puts them. | > 3 studs (and > 1.5 × the prop's own size). |
| **Scale sanity** | Prop height or width compared with a small table of plausible real-world sizes (`SCALE_HINTS`). | Outside the range; suggests an ArtScale. A heuristic only. |
| **Camera clipping** | For props taller than 1.2 studs (or wall-mounted), mesh points between 3 and 6.5 studs high that lie within 1 stud of floor a body can reach face-first (radius 0.5). Overhang is the horizontal distance from those points to the footprint of the nearest CanCollide part a walking body bumps into (0.4–5.5 studs). | Eye zone 4.0–5.8: overhang > 0.3 can put the first-person camera inside the mesh. Overhangs outside the eye zone are low priority. |
| **Walkability** | CanCollide parts in the 0.4–5.5 band are rasterised to a 0.25-stud grid over the Layout areas. Floors are parts whose top sits at y ≈ 0, and cells without floor are blocked. Clearance comes from an exact distance transform, and a character of radius 1.0 is flood-filled from the `SpawnLocation`. The rear and front doors are treated as open (they stop colliding when opened). | Pockets of standable but unreachable floor are tinted orange. |
| **Interactables** | Targets come from `MapBuilder.refs` (desk towers, dock, seat, rack and slots, breakers, rear door, kitchen trash, dumpster, thermostat, printer, out tray, time clock, notice board, escape zone). Prompt labels and distances are parsed from the `Prompts.make` calls in `src/server`. A target is reachable when a reachable cell lies within its prompt distance minus 1 stud, measured in 3D from a root height of 3. | Unreachable targets are critical. |
| **Routes** | Widest path from the spawn to each target. Width is twice the clearance at the bottleneck, which is marked on the plan. Bottlenecks inside a Layout door opening are labelled as doorways. | < 3.5 studs (art direction). |
| **Chairs** | Free floor behind each desk chair, marched in the direction away from the desk across the chair's width, until it meets collision, a floor-standing prop or the end of the floor. Facing: the backrest (top quarter of the mesh) gives the seat's front, compared with the desk direction. | < 2.5 studs free behind; facing off by > 45°. |
| **Clutter** | Art props per area (Layout regions) and per desk (PC kit and personal items). Keys matching weathered, rust, trash, litter, boarded, hazard and similar words are listed, along with dirty surface textures indoors. | Weathered keys indoors. |
| **Lights** | Every Light by area: amber, neutral, cold, emergency or status, classified by colour. Dot size on the plan is proportional to range. | Information only. |

Tunables (grid size, radii, thresholds) are the constants at the top of
`analyze.py`.

## Limitations

- Prop shapes are bounding boxes and sampled triangle surfaces, not the
  engine's collision or render geometry. A mesh-confirmed overlap means the
  surfaces come within about 0.1 stud of each other. It cannot tell an
  intentional flush fit from a visible clip.
- There is no physics. Characters are discs of radius 1.0 (0.5 face-first) on
  a 0.25-stud grid, so widths are accurate to about ±0.25 stud. Step-up, slopes,
  seats and the Humanoid's real hitbox are not modelled.
- Prompt reach is approximated from the prompt parent's position at a root
  height of 3 studs. The custom prompt UI and line of sight are not
  simulated, and prompts created at runtime on characters (revive) are skipped.
- Only MapBuilder runs. Other server systems (Doors, Drives, Workstation and
  so on) are not started, so doors stay in their built pose, and the audit
  treats them as open for walking.
- Lighting is reported as data only. `render.py` is a Lambert rasteriser
  without shadows, fog, bloom, the client Atmosphere controller or Future
  lighting. Its images say "approximate offline render, not Studio lighting" and
  are useful for judging layout, facing and clutter, not mood.
- Client-side art limits (the EditableMesh budget in `ArtController`) are not
  simulated. A prop that the client skips for budget reasons still appears here.
