"""
Presentation rule check (docs/ART_DIRECTION.md), static and heuristic.

Flags:
  corner      UICorner instances (panels are square in this art direction)
  enum-font   Enum.Font.* outside src/shared/Fonts.luau (families come from Fonts / UiKit)
  small-text  literal TextSize below 13 for readable (non-pixel) text, or below 8 for pixel text
  long-pixel  Silkscreen (FONT_PIXEL / Fonts.PIXEL) on a literal text longer than 28 characters

Usage: python3 tools/check_presentation.py [paths...]   (default src/client src/server src/shared)
Exit code 1 when anything is flagged; review each hit, some may be intentional.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

MIN_TEXT = 13
MIN_PIXEL = 8
MAX_PIXEL_CHARS = 28

PIXEL_FONT = re.compile(r"\b(?:UiKit\.FONT_PIXEL(?:_BOLD)?|Fonts\.PIXEL(?:_BOLD)?|TYPE\.(?:title|display|key))\b")
TEXT_LIT = re.compile(r'\bText\s*=\s*"((?:[^"\\]|\\.)*)"')
TEXT_SIZE = re.compile(r"\bTextSize\s*=\s*(\d+(?:\.\d+)?)\b")


def statements(src: str):
    """Yield (line, chunk) for each brace-balanced table literal and each line."""
    depth = 0
    start = None
    for i, ch in enumerate(src):
        if ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}" and depth > 0:
            depth -= 1
            if depth == 0 and start is not None:
                yield src.count("\n", 0, start) + 1, src[start : i + 1]
                start = None


def check(path: Path) -> list[str]:
    src = path.read_text(encoding="utf-8")
    rel = str(path)
    out = []
    code_lines = [(n + 1, ln) for n, ln in enumerate(src.splitlines()) if not ln.strip().startswith("--")]
    for n, ln in code_lines:
        if "UICorner" in ln:
            out.append(f"{rel}:{n}: corner: {ln.strip()[:120]}")
        if "Enum.Font." in ln and not rel.endswith("shared/Fonts.luau"):
            out.append(f"{rel}:{n}: enum-font: {ln.strip()[:120]}")
    for line, chunk in statements(src):
        is_pixel = bool(PIXEL_FONT.search(chunk.split("{", 1)[1][:400])) if "{" in chunk else False
        # only judge the innermost-looking tables (a single Text/TextSize pair)
        if chunk.count("{") > 3:
            continue
        for m in TEXT_SIZE.finditer(chunk):
            size = float(m.group(1))
            limit = MIN_PIXEL if is_pixel else MIN_TEXT
            if size < limit:
                out.append(f"{rel}:{line}: small-text: TextSize {m.group(1)} ({'pixel' if is_pixel else 'readable'})")
        if is_pixel:
            for m in TEXT_LIT.finditer(chunk):
                if len(m.group(1)) > MAX_PIXEL_CHARS:
                    out.append(f'{rel}:{line}: long-pixel: "{m.group(1)[:60]}" ({len(m.group(1))} chars)')
    return out


def main() -> int:
    paths = sys.argv[1:] or ["src/client", "src/server", "src/shared"]
    files: list[Path] = []
    for p in paths:
        pp = Path(p)
        files += sorted(pp.rglob("*.luau")) if pp.is_dir() else [pp]
    hits: list[str] = []
    for f in files:
        if "/art/" in str(f):
            continue
        hits += check(f)
    for h in hits:
        print(h)
    kinds: dict[str, int] = {}
    for h in hits:
        k = h.split(": ", 2)[1] if ": " in h else "?"
        kinds[k] = kinds.get(k, 0) + 1
    print(f"{len(files)} files: {len(hits)} flag(s) {kinds}")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
