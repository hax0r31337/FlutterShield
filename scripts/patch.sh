#!/usr/bin/env bash
set -euo pipefail

FLUTTER_VERSION="3.47.6"
BASE_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_DIR="$ROOT/flutter_bin"
PATCH_FILE="$ROOT/patch.diff"

case "$(uname -s)" in
    Linux*)
        ARCHIVE="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
        URL="$BASE_URL/linux/$ARCHIVE"
        ;;
    MINGW* | MSYS* | CYGWIN*)
        ARCHIVE="flutter_windows_${FLUTTER_VERSION}-stable.zip"
        URL="$BASE_URL/windows/$ARCHIVE"
        ;;
    *)
        echo "unsupported platform: $(uname -s)" >&2
        exit 1
        ;;
esac

if [[ -d "$FLUTTER_DIR" ]]; then
    echo "flutter_bin already exists, resetting to HEAD"
    git -C "$FLUTTER_DIR" reset --hard HEAD
    # drop files added by a previous patch, keep ignored caches (bin/cache etc.)
    git -C "$FLUTTER_DIR" clean -fd
else
    # extract next to the target so the final move is a cheap rename
    TMP_DIR="$(mktemp -d "$ROOT/.flutter_dl.XXXXXX")"
    trap 'rm -rf "$TMP_DIR"' EXIT

    echo "downloading $URL"
    curl -fL --retry 3 -o "$TMP_DIR/$ARCHIVE" "$URL"

    echo "extracting $ARCHIVE"
    case "$ARCHIVE" in
        *.tar.xz) tar -xJf "$TMP_DIR/$ARCHIVE" -C "$TMP_DIR" ;;
        *.zip) unzip -q "$TMP_DIR/$ARCHIVE" -d "$TMP_DIR" ;;
    esac

    # archives contain a single top-level flutter/ directory
    mv "$TMP_DIR/flutter" "$FLUTTER_DIR"
fi

if [[ ! -s "$PATCH_FILE" ]]; then
    echo "patch.diff is empty or missing, nothing to apply"
else
    echo "applying patch.diff"
    git -C "$FLUTTER_DIR" apply "$PATCH_FILE"
fi

# The flutter tool snapshot is only rebuilt when the checkout's revision
# changes, which patching the tool's sources does not do.
rm -f "$FLUTTER_DIR/bin/cache/flutter_tools.stamp"

# The vendored SDK packages are needed to read and write the snapshots.
"$ROOT/scripts/vendor.sh"
