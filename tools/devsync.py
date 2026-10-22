"""
Dev-only helper: writes build/manifest.json describing every Luau source file
and the instance path Rojo would map it to (per default.project.json).
tools/devsync.luau (pasted into Studio's command bar, with the project served
over http://127.0.0.1:34999) pulls changed files into an open place.

Rojo remains the real build path:  rojo build default.project.json -o build/NightShift.rbxlx
"""

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

MOUNTS = [
    ("src/shared", "ReplicatedStorage.Shared", "Folder"),
    ("src/art", "ReplicatedStorage.ArtData", "Folder"),
    ("src/server", "ServerScriptService.Server", "Folder"),
    ("src/client", "StarterPlayer.StarterPlayerScripts.Client", "Folder"),
]


def classify(path: Path):
    name = path.name
    if name.endswith(".server.luau"):
        return name[: -len(".server.luau")], "Script"
    if name.endswith(".client.luau"):
        return name[: -len(".client.luau")], "LocalScript"
    return name[: -len(".luau")], "ModuleScript"


def main():
    entries = []
    for src, target, root_class in MOUNTS:
        base = ROOT / src
        for f in sorted(base.rglob("*.luau")):
            rel = f.relative_to(base)
            stem, cls = classify(f)
            parts = list(rel.parts[:-1])
            if stem == "init":
                inst_path = target + ("." + ".".join(parts) if parts else "")
            else:
                inst_path = target + ("." + ".".join(parts) if parts else "") + "." + stem
            data = f.read_bytes()
            entries.append({
                "path": inst_path,
                "class": cls,
                "url": "/" + f.relative_to(ROOT).as_posix(),
                "hash": hashlib.sha1(data).hexdigest()[:16],
            })
    (ROOT / "build").mkdir(exist_ok=True)
    (ROOT / "build" / "manifest.json").write_text(json.dumps(entries), encoding="utf-8")
    print(len(entries), "files")


if __name__ == "__main__":
    main()
