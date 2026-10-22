#!/usr/bin/env bash
# Headless layout audit: runs the real MapBuilder in Lune, then analyses it.
#
#   bash tools/audit/run.sh                       # audit the working tree as "current"
#   bash tools/audit/run.sh --label before --src /path/to/other/checkout
#   bash tools/audit/run.sh --label current --views  # also render approximate eye-height views
#
# Options:
#   --label NAME      output name (default: current)
#   --src DIR         source tree to audit: a checkout root or its src/ (default: this repo)
#   --baseline NAME   compare against tools/audit/out/NAME.json (default: before, when it exists)
#   --views           also run tools/audit/render.py (slower, approximate offline renders)
#   --describe TEXT   how the source is named in the report (default: path @ git revision)
#
# Outputs: tools/audit/out/NAME.json, docs/presentation/plan-NAME.png,
#          docs/presentation/layout-audit-NAME.md (+ view-NAME-N.png with --views).
# Needs: lune (LUNE=... or on PATH, else /root/bin/lune), python3 with numpy + Pillow.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LABEL="current"
SRC="$ROOT/src"
BASELINE=""
VIEWS=0
DESCRIBE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--label) LABEL="${2:?--label needs a value}"; shift 2 ;;
		--src) SRC="${2:?--src needs a value}"; shift 2 ;;
		--baseline) BASELINE="${2:?--baseline needs a value}"; shift 2 ;;
		--views) VIEWS=1; shift ;;
		--describe) DESCRIBE="${2:?--describe needs a value}"; shift 2 ;;
		-h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
		*) echo "run.sh: unknown option $1 (see --help)" >&2; exit 64 ;;
	esac
done

case "$LABEL" in
	*[!A-Za-z0-9_.-]*|"") echo "run.sh: --label may only contain letters, digits, '.', '_' and '-'" >&2; exit 64 ;;
esac

SRC="$(cd "$SRC" && pwd)"
if [ -d "$SRC/src/server" ]; then
	SRC="$SRC/src"
fi
if [ ! -f "$SRC/server/Systems/MapBuilder.luau" ]; then
	echo "run.sh: $SRC does not contain server/Systems/MapBuilder.luau" >&2
	exit 66
fi

LUNE="${LUNE:-$(command -v lune || true)}"
[ -z "$LUNE" ] && [ -x /root/bin/lune ] && LUNE=/root/bin/lune
if [ -z "$LUNE" ]; then
	echo "run.sh: lune not found (install Lune 0.10.x or set LUNE=/path/to/lune)" >&2
	exit 69
fi
PYTHON="${PYTHON:-python3}"
"$PYTHON" -c "import numpy, PIL" 2>/dev/null || { echo "run.sh: $PYTHON needs numpy and Pillow" >&2; exit 69; }

OUT="$HERE/out"
DOCS="$ROOT/docs/presentation"
mkdir -p "$OUT" "$DOCS"
DUMP="$OUT/$LABEL.dump.json"

if [ -z "$BASELINE" ] && [ "$LABEL" != "before" ] && [ -f "$OUT/before.json" ]; then
	BASELINE="before"
fi
BASEARG=()
if [ -n "$BASELINE" ]; then
	if [ -f "$OUT/$BASELINE.json" ]; then
		BASEARG=(--baseline "$OUT/$BASELINE.json")
	else
		echo "run.sh: no $OUT/$BASELINE.json yet; skipping the comparison" >&2
	fi
fi

DISPLAY_SRC="$SRC"
case "$SRC" in "$ROOT"/*) DISPLAY_SRC="${SRC#"$ROOT"/}" ;; esac
REV=""
if git -C "$SRC" rev-parse --short HEAD >/dev/null 2>&1; then
	REV="$(git -C "$SRC" rev-parse --short HEAD)"
	if [ -n "$(git -C "$SRC" status --porcelain -- . 2>/dev/null | head -1)" ]; then
		REV="$REV+local changes"
	fi
	DISPLAY_SRC="$DISPLAY_SRC @ $REV"
fi
[ -n "$DESCRIBE" ] && DISPLAY_SRC="$DESCRIBE"

start=$(date +%s)
echo "== harness: building the map headlessly from $DISPLAY_SRC"
"$LUNE" run "$HERE/harness.luau" "$SRC" "$DUMP"
echo "== analysis"
"$PYTHON" "$HERE/analyze.py" --dump "$DUMP" --src "$SRC" --label "$LABEL" \
	--out-json "$OUT/$LABEL.json" --png "$DOCS/plan-$LABEL.png" --md "$DOCS/layout-audit-$LABEL.md" \
	--src-display "$DISPLAY_SRC" ${BASEARG[@]+"${BASEARG[@]}"}
if [ "$VIEWS" = 1 ]; then
	echo "== approximate views"
	"$PYTHON" "$HERE/render.py" --dump "$DUMP" --src "$SRC" --label "$LABEL" --out-dir "$DOCS"
fi
echo "== done in $(( $(date +%s) - start ))s"
echo "   report  docs/presentation/layout-audit-$LABEL.md"
echo "   plan    docs/presentation/plan-$LABEL.png"
echo "   json    tools/audit/out/$LABEL.json"
