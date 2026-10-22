"""
Static check for UiKit property tables.

UiKit.new / label / frame / text / panel take `{ [string]: any }` property
tables, so luau-lsp cannot catch a misspelled or wrong-class property such as
`TextSzie = 14` or `TextColor3` on a Frame; Roblox would only throw at
runtime. This script finds those calls, resolves the instance class, and
checks every top-level key against the Roblox API dump (with inheritance).

Usage:
    python3 tools/check_ui_props.py --api API-Dump.json [paths...]
The API dump is the public one from MaximumADHD/Roblox-Client-Tracker
(roblox branch, API-Dump.json). Exit code 1 when problems are found.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# helper -> class it creates (None: class given as the first string argument)
HELPERS = {
    "UiKit.new": None,
    "UiKit.label": "TextLabel",
    "UiKit.text": "TextLabel",
    "UiKit.frame": "Frame",
    "UiKit.panel": "Frame",
}
# keys UiKit itself consumes or remaps (Font objects go to FontFace)
EXTRA_KEYS = {"Parent", "Font"}

CALL = re.compile(r"(UiKit\.(?:new|label|text|frame|panel))\s*\(")


def load_classes(api_path: Path) -> dict[str, tuple[str, set[str]]]:
    api = json.loads(api_path.read_text(encoding="utf-8"))
    classes: dict[str, tuple[str, set[str]]] = {}
    for c in api["Classes"]:
        props = {m["Name"] for m in c["Members"] if m["MemberType"] == "Property"}
        classes[c["Name"]] = (c["Superclass"], props)
    return classes


def all_props(classes, name: str) -> set[str] | None:
    if name not in classes:
        return None
    out: set[str] = set()
    while name in classes:
        sup, props = classes[name]
        out |= props
        name = sup
    return out


def strip_comments_and_strings(src: str) -> str:
    """Blank out comments and string contents (keeping offsets) so brace
    matching and key scanning are not confused by text."""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        ch = src[i]
        if src.startswith("--[[", i) or src.startswith("--[=[", i):
            end = src.find("]]", i) if src.startswith("--[[", i) else src.find("]=]", i)
            end = n if end < 0 else end + 2
            for k in range(i, end):
                if out[k] != "\n":
                    out[k] = " "
            i = end
        elif src.startswith("--", i):
            end = src.find("\n", i)
            end = n if end < 0 else end
            for k in range(i, end):
                out[k] = " "
            i = end
        elif ch in "\"'`":
            q = ch
            j = i + 1
            while j < n and src[j] != q:
                if src[j] == "\\":
                    j += 1
                j += 1
            for k in range(i + 1, min(j, n)):
                if out[k] != "\n":
                    out[k] = " "
            i = j + 1
        elif src.startswith("[[", i):
            end = src.find("]]", i)
            end = n if end < 0 else end + 2
            for k in range(i + 2, end - 2):
                if out[k] != "\n":
                    out[k] = " "
            i = end
        else:
            i += 1
    return "".join(out)


def match_close(s: str, open_idx: int, op: str, cl: str) -> int:
    depth = 0
    for k in range(open_idx, len(s)):
        if s[k] == op:
            depth += 1
        elif s[k] == cl:
            depth -= 1
            if depth == 0:
                return k
    return -1


def top_level_keys(body: str) -> list[tuple[str, int]]:
    """Identifier keys (`Key = value`) at depth 0 of a table body."""
    keys = []
    depth = 0
    i = 0
    starts_entry = True
    while i < len(body):
        ch = body[i]
        if ch in "({[":
            depth += 1
        elif ch in ")}]":
            depth -= 1
        elif depth == 0 and ch in ",;":
            starts_entry = True
            i += 1
            continue
        elif depth == 0 and starts_entry and (ch.isalpha() or ch == "_"):
            m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)", body[i:])
            if m:
                keys.append((m.group(1), i))
                i += m.end()
                starts_entry = False
                continue
            starts_entry = False
        elif not ch.isspace():
            starts_entry = False
        i += 1
    return keys


def check_file(path: Path, classes) -> tuple[list[str], int]:
    raw = path.read_text(encoding="utf-8")
    src = strip_comments_and_strings(raw)
    problems = []
    validated = 0
    for m in CALL.finditer(src):
        helper = m.group(1)
        paren = m.end() - 1
        close = match_close(src, paren, "(", ")")
        if close < 0:
            continue
        args_clean = src[paren + 1 : close]
        args_raw = raw[paren + 1 : close]
        cls = HELPERS[helper]
        if cls is None:
            cm = re.match(r'\s*"([A-Za-z]+)"\s*,', args_raw)
            if not cm:
                continue  # class from a variable: cannot resolve statically
            cls = cm.group(1)
        brace = args_clean.find("{")
        if brace < 0:
            continue  # props passed as a variable
        # the props table must be the next argument (after the class / role string)
        before = args_clean[:brace].strip().rstrip(",").strip()
        if helper in ("UiKit.new", "UiKit.text"):
            if before.count(",") > 0:
                continue
        elif before:
            continue
        end = match_close(args_clean, brace, "{", "}")
        if end < 0:
            continue
        props = all_props(classes, cls)
        line = raw.count("\n", 0, paren) + 1
        validated += 1
        if props is None:
            problems.append(f"{path}:{line}: unknown class '{cls}' in {helper}")
            continue
        for key, _ in top_level_keys(args_clean[brace + 1 : end]):
            if key not in props and key not in EXTRA_KEYS:
                problems.append(f"{path}:{line}: '{key}' is not a property of {cls} ({helper})")
    return problems, validated


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", required=True, type=Path)
    ap.add_argument("paths", nargs="*", default=["src/client", "src/server"])
    args = ap.parse_args()
    classes = load_classes(args.api)
    files: list[Path] = []
    for p in args.paths:
        pp = Path(p)
        files += sorted(pp.rglob("*.luau")) if pp.is_dir() else [pp]
    problems: list[str] = []
    calls = 0
    validated = 0
    for f in files:
        calls += len(CALL.findall(f.read_text(encoding="utf-8")))
        found, n = check_file(f, classes)
        problems += found
        validated += n
    for p in problems:
        print(p)
    print(
        f"{calls} UiKit calls in {len(files)} files, {validated} literal property tables validated: "
        f"{len(problems)} problem(s)"
    )
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
