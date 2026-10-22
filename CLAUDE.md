# Claude Code cloud handoff

Read `docs/NEXT_SESSION.md`, `studio/export-manifest.json`, and `assets/README.md` first.

This repository contains a native snapshot and editable source exported from the user's selected **NightShift.rbxlx** Studio session. All 195 saved script sources were checked against the live Studio contents after normalizing CRLF/LF. `src/` is the authoritative Studio baseline; `studio/NightShift.snapshot.rbxlx` preserves the native edit state. `build/NightShift.rbxlx` is the playable saved place. The map and desktop UI are built at runtime, so an empty edit-mode viewport is expected.

The loose local source folder contained a different revision, including cleaner asset choices and UI/camera work. It is preserved under `studio/local-working-tree/`. Compare it before reimplementing the requested presentation changes. Do not silently discard either version. Those reference files are not mounted by the main Rojo project.

## Work from GitHub without MCP

- This cloud session cannot directly inspect or alter the user's running Studio instance. Do not claim live application or Studio playtesting from repository edits alone.
- Edit Luau and `default.project.json`, run available static checks, and rebuild with `rojo build default.project.json -o build/NightShift.rbxlx`. The pinned tool versions are in `rokit.toml`.
- Keep the native Studio snapshot as an immutable export reference. Commit the rebuilt place alongside meaningful code changes when it is ready for local testing.
- Do not add user avatars, runtime CoreScripts, invented asset IDs or test-generated runtime map instances to the persistent source.
- Do not start a broad bug-fixing pass before the user's atmosphere, clutter, first-person and interface requests in `docs/NEXT_SESSION.md` are addressed.

## Assets, fetched only as needed

All supplied assets are hosted on this same repository's `nightshift-assets-v1` GitHub release. `assets/library-manifest.json` indexes all 6,402 files with package locations, byte offsets and SHA256 hashes. It includes all 21 original archives, 105 original loose files, 1,069 prepared model/scene entries, texture variants, character sources and all ten WAVs. No Git LFS login or local Windows file access is needed.

Catalogs, individual previews and contact sheets are already checked into `assets/context/`. Start there. To retrieve one model and its linked textures:

```sh
python tools/fetch_assets.py --key office__desks__desk1_corner_weathered
python tools/fetch_assets.py --key characters__male__character_01
```

The default downloads only the selected files using HTTP range requests, verifies their hashes and writes to ignored `assets/library/`. `--texture KEY`, `--audio KEY` and `--file RELATIVE_PATH` retrieve other supplied files. `--list` reports the manifest. If a network proxy ignores ranges, `--package core` downloads the complete core archive as a fallback. `--all` retrieves every supplied original and prepared file; do not do that by default.

Allow network access to GitHub release download hosts when the cloud environment requires it: `github.com`, `release-assets.githubusercontent.com` and redirected GitHub asset hosts. Report network failures accurately rather than treating missing local files as missing supplied assets.

The current game carries its selected geometry and textures in `src/art` and renders them with EditableMesh/EditableImage APIs. It can be rebuilt without downloading the entire raw library. To change the selection, fetch the chosen source files, reconcile the converter selection with MapBuilder and `ArtData.Index`, then regenerate with `python tools/convert_assets.py --library assets/library --out src/art`. The converter also needs its configured surface textures and the carpet source model. Do not regenerate art blindly: its current selection reflects the preserved loose working revision, while `src/art` reflects the exported Studio baseline.

Preserve supplied licenses and provenance. The repository's MIT license does not relicense third-party asset packs.
