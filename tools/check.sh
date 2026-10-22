#!/usr/bin/env bash
# Static checks: Rojo sourcemap + luau-lsp strict type analysis + selene lint.
# Usage: bash tools/check.sh [paths...]   (defaults to src/shared src/server src/client)
set -u
cd "$(dirname "$0")/.."
TOOLS="${TOOLS:-$HOME/tools}"
"$TOOLS/rojo/rojo.exe" sourcemap default.project.json -o sourcemap.json >/dev/null
PATHS="${*:-src/shared src/server src/client}"
"$TOOLS/luau-lsp/luau-lsp.exe" analyze --sourcemap=sourcemap.json \
	--definitions="$TOOLS/luau-lsp/globalTypes.d.luau" --ignore="src/art/**" $PATHS 2>&1 \
	| grep -E "^c:|^[A-Za-z]:" | sed -E 's#^.*night-shift[\\/]##; s#\[game[^]]*\]##' | sort -u | cut -c1-260
echo "--- typecheck done"
