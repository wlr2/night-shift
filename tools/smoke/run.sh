#!/usr/bin/env bash
# Headless smoke harness for the NIGHT SHIFT client (Lune, not Roblox).
# Usage: bash tools/smoke/run.sh [--verbose] [--only=c,d] [--no-editables]
#                                [--no-camera-scripts] [--profile]
# Exit status: 0 all scenarios PASS/WARN, 1 a scenario FAILed, 2-3 setup error.
# See tools/smoke/README.md for coverage and limitations.
set -u
cd "$(dirname "$0")/../.."
LUNE="${LUNE:-}"
if [ -z "$LUNE" ]; then
	for cand in "$(command -v lune 2>/dev/null)" "$HOME/.rokit/bin/lune" "$HOME/.aftman/bin/lune" /root/bin/lune; do
		if [ -n "$cand" ] && [ -x "$cand" ]; then
			LUNE="$cand"
			break
		fi
	done
fi
if [ -z "$LUNE" ]; then
	echo "smoke: lune not found (install lune-org/lune 0.10.x or set LUNE=/path/to/lune)" >&2
	exit 2
fi
exec "$LUNE" run tools/smoke/main.luau "$@"
