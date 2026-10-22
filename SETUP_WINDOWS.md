# Windows setup

## 1. Just play

1. Open `build\NightShift.rbxlx` in Roblox Studio (double-click it).
2. Press **Play** (F5). First load shows "clocking in…" for a second while the
   props are baked into meshes.
3. For co-op in Studio: **Test → Clients and Servers**, choose 2–4 players, **Start**.

To publish: File → Publish to Roblox. Then read the EditableMesh note in README.md
and set up audio (step 4).

## 2. Toolchain (only needed to rebuild or edit code)

The project uses [Rojo](https://rojo.space) 7.7.1. Install either way:

- With Rokit (recommended): install Rokit, then in this folder run `rokit install`
  (reads `rokit.toml`: rojo, selene, stylua, luau-lsp).
- Manually: download `rojo-7.7.1-windows-x86_64.zip` from
  https://github.com/rojo-rbx/rojo/releases and put `rojo.exe` on your PATH.

Python 3.10+ with Pillow is only needed if you re-convert art:
`pip install pillow`.

## 3. Build the place file

From the `night-shift` folder (PowerShell or Git Bash):

```bash
rojo build default.project.json -o build/NightShift.rbxlx
```

### Live-sync while editing

```bash
rojo serve default.project.json
```

Install the Rojo Studio plugin once (`rojo plugin install`), open the built place,
then in Studio: Plugins → Rojo → Connect.

## 4. Audio (optional but strongly recommended)

Roblox only plays uploaded audio, so the game ships with empty sound IDs.

1. Generate the clips (already done once; re-run any time):
   ```bash
   python tools/make_audio.py --library ..
   ```
   This writes `audio-upload\*.wav`: three 90-second excerpts of your PSX Ambient
   Pack (Still, Distant, Hollow) plus original procedural rain, fan hum, chime,
   breaker, knock, footsteps, phone, error, click and door-slam sounds.
2. In Studio: **Window → Asset Manager → Bulk Import**, select all the WAVs.
3. Right-click each imported sound → Copy Asset ID, and paste it into
   `src/shared/Config.luau` → `Config.SOUNDS` as `"rbxassetid://<id>"`
   (the keys match the file names).
4. Rebuild (step 3).

## 5. Re-converting the art library (optional)

The converted data in `src/art` is generated from the NightShiftAssets folder:

```bash
python tools/convert_assets.py --library .. --out src/art
```

The selected asset keys are listed at the top of `tools/convert_assets.py`; add a key
there and place it in `src/server/Systems/MapBuilder.luau` with `prop(...)`.

## 6. Checks

```bash
bash tools/check.sh          # Rojo sourcemap + luau-lsp strict type check
selene src/shared src/server src/client
```

Minigame logic specs: in Studio Edit mode, put the contents of
`tools/tests/MinigameSpecs.luau` in a ModuleScript and run `require(module)()` from the
command bar; it prints a per-game summary ending in `ALL PASSED`.

QA cheats work automatically in Studio (and for UserIds in `Config.DEV_USER_IDS`) via the
`Cheat` remote, e.g. from a client: `game.ReplicatedStorage.Remotes.Cheat:FireServer("eraseAll", 5)`.
Commands: `state, log, erase, eraseAll, solve, event <id>, power, door, hunt, finale,
signoff <0..1>, clockout, down, restore, tp <office|workstation|kitchen|hall|alley|lobby|rack>`.
