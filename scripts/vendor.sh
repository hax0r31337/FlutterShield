#!/usr/bin/env bash
set -euo pipefail

# package:kernel reads and writes the snapshots, and package:vm holds the
# metadata repositories that have to be registered for the VM's own metadata
# (type flow analysis results, dispatch tables, ...) to survive the round trip.
#
# Neither is published on pub.dev, and the copies in the Dart SDK repository are
# workspace members, so they cannot be used as git dependencies either. Vendor
# them as plain path dependencies instead.
#
# Must match the Dart SDK that ships with the flutter version in patch.sh,
# otherwise the dill binary format version will not line up.
DART_VERSION="3.13.5"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="$ROOT/kernel_pkg"
VM_DIR="$ROOT/vm_pkg"
SDK_VERSION_FILE="$ROOT/flutter_bin/bin/cache/dart-sdk/version"

if [[ -f "$SDK_VERSION_FILE" ]]; then
    BUNDLED="$(tr -d '[:space:]' < "$SDK_VERSION_FILE")"
    if [[ "$BUNDLED" != "$DART_VERSION" ]]; then
        echo "warning: flutter_bin ships dart $BUNDLED, vendoring packages from $DART_VERSION" >&2
    fi
fi

if [[ "$(cat "$KERNEL_DIR/.version" 2>/dev/null)" == "$DART_VERSION" ]] &&
    [[ "$(cat "$VM_DIR/.version" 2>/dev/null)" == "$DART_VERSION" ]]; then
    echo "kernel_pkg and vm_pkg already at $DART_VERSION"
    exit 0
fi

TMP_DIR="$(mktemp -d "$ROOT/.vendor_dl.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "fetching pkg/kernel and pkg/vm from dart-lang/sdk $DART_VERSION"
git clone --filter=blob:none --no-checkout --depth 1 --branch "$DART_VERSION" \
    https://github.com/dart-lang/sdk.git "$TMP_DIR/sdk" 2>&1 | grep -v "^warning: refs/tags" || true
git -C "$TMP_DIR/sdk" sparse-checkout set --no-cone pkg/kernel pkg/vm >/dev/null
git -C "$TMP_DIR/sdk" checkout >/dev/null

# `resolution: workspace` only works inside the SDK checkout, and the SDK pins
# its dependency versions through DEPS rather than through the pubspecs. Only
# the dependencies of the libraries actually imported are declared here; the
# parts of package:vm that pull in package:front_end are never loaded.
vendor() {
    local source="$1" target="$2"
    rm -rf "$target"
    mkdir -p "$target"
    cp -r "$source/lib" "$source/LICENSE" "$target/"
    cp "$source/README.md" "$target/" 2>/dev/null || true
    cat > "$target/pubspec.yaml"
    echo "$DART_VERSION" > "$target/.version"
}

vendor "$TMP_DIR/sdk/pkg/kernel" "$KERNEL_DIR" <<'PUBSPEC'
# Vendored from dart-lang/sdk pkg/kernel by scripts/vendor.sh. Do not edit.
name: kernel
publish_to: none

environment:
  sdk: ^3.13.0

dependencies:
  _fe_analyzer_shared: any
PUBSPEC

vendor "$TMP_DIR/sdk/pkg/vm" "$VM_DIR" <<'PUBSPEC'
# Vendored from dart-lang/sdk pkg/vm by scripts/vendor.sh. Do not edit.
name: vm
publish_to: none

environment:
  sdk: ^3.13.0

dependencies:
  collection: any
  kernel:
    path: ../kernel_pkg
PUBSPEC

echo "vendored kernel_pkg and vm_pkg at $DART_VERSION"
