# Complete external asset library

The metadata and previews in `context/` are available directly in Git. Actual binaries are hosted in the [asset release](https://github.com/wlr2/night-shift/releases/tag/nightshift-assets-v1), split into three independently verified ZIPs:

- **core**: prepared models, linked textures, editable source derivatives, catalogs and previews.
- **audio**: all ten complete ambient WAVs.
- **originals**: every one of the 21 supplied archives and all 105 loose files from the original folder, unchanged.

Together they preserve exactly the 6,402 files in the complete handoff. `library-manifest.json` maps every relative path to its package, byte offset, size and SHA256 digest. Original file copies were checked against their source hashes. The package ZIPs were CRC checked. See `context/PACK_COVERAGE.md` and `context/provided-files-manifest.json` for coverage.

Fetch assets as needed, without downloading a complete ZIP:

```sh
python tools/fetch_assets.py --list
python tools/fetch_assets.py --key office__computers__computer_monitor
python tools/fetch_assets.py --key characters__male__character_01
python tools/fetch_assets.py --texture HORROR_TEXTURE_KEY
python tools/fetch_assets.py --file "provided-files/downloads/buildings.zip"
```

Use exact texture and audio keys from their catalogs; the uppercase example is a placeholder. A model fetch includes catalog-linked texture images. Downloads land in `assets/library/`, which is ignored by Git. Selected character FBXs retain their skeletons and source data; compatibility and Roblox animation playback still need testing.

If HTTP ranges are unavailable, fetch a package instead:

```sh
python tools/fetch_assets.py --package core
python tools/fetch_assets.py --package audio
python tools/fetch_assets.py --package originals
python tools/fetch_assets.py --all
```

The three packages total about 3.45 GB. Do not fetch everything merely to change the UI or gameplay. No bulk import into Studio is required. The old 20-model starter was deleted by the user.

The asset context's historical Windows paths describe the source machine, not paths available inside Claude cloud. Use `preparedFile` and other library-relative paths through the fetcher. Current repository instructions take precedence over older workflow documents inside the preserved handoff.

Two original archives contain packaged Unreal demos rather than reusable source meshes. They are included intact for completeness; do not execute archived programs. Four Classic 64 scenes have no embedded texture; all originals and supplied images are preserved, and known limitations are listed in `context/limitations.json`.
