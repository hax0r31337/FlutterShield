#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_DIR="$ROOT/flutter_bin"
PATCH_FILE="$ROOT/patch.diff"

if [[ ! -d "$FLUTTER_DIR" ]]; then
    echo "flutter_bin not found, run scripts/patch.sh first" >&2
    exit 1
fi

# stage everything into a throwaway index so new files are included
# without touching flutter_bin's real index
TMP_INDEX="$(mktemp)"
trap 'rm -f "$TMP_INDEX"' EXIT
cp "$(git -C "$FLUTTER_DIR" rev-parse --path-format=absolute --git-path index)" "$TMP_INDEX"

GIT_INDEX_FILE="$TMP_INDEX" git -C "$FLUTTER_DIR" add -A
GIT_INDEX_FILE="$TMP_INDEX" git -C "$FLUTTER_DIR" diff --cached --binary HEAD > "$PATCH_FILE"

echo "wrote $(git -C "$FLUTTER_DIR" apply --numstat "$PATCH_FILE" 2>/dev/null | wc -l) file(s) to patch.diff"
