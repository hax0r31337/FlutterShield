# FlutterShield

A compile time pass patch for Flutter that adds obfuscation capabilities beyond the default Dart --obfuscation renaming.

## Usage

```bash
# setup: downloads the flutter SDK into flutter_bin, patches it, and vendors
# the SDK packages the tool needs to read and write kernel snapshots
./scripts/patch.sh

# use the flutter command as normal, pass env FS_PACKAGE in regex for package filtering
# pair with --obfuscate to rename symbols
./flutter_bin/bin/flutter build apk --release --dart-define=FS_PACKAGE=^my_package_name$ --obfuscate
```

The passes run as part of the `kernel_snapshot_program` build step of a
**release** build, on the snapshot the front end just produced and before
`gen_snapshot` turns it into machine code. A build that passes no `FS_`-prefixed
dart define does not run FlutterShield at all; once one is passed, `FS_PACKAGE`
is required and the build fails without it.

### Configuration

Dart defines are not visible to the processes of a build, so the `FS_`-prefixed
ones are handed to the tool as environment variables.

| Define       | Meaning                                                                                                                                                                                                                                                                                                                                  |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `FS_PACKAGE` | **(required)** Regex matched against the package name of each library. Only `package:` libraries are ever selected; `dart:` and loose `file:` libraries are always left alone. The regex is not anchored for you, so `^my_app$` selects `package:my_app/...` and nothing else, while `my_app` would also select `package:my_app_models`. |
| `FS_SEED`    | Fixed seed for the random choices the passes make, for a reproducible build. A random seed is drawn per build when unset.                                                                                                                                                                                                               |

## Features

- Field shuffling

The classes of the selected libraries get their fields declared in a random
order. Nothing in a Dart program can read that order back out, but the VM lays
its objects out in it, so it decides the slot every field ends up at - and in
AOT code with `--obfuscate` a field access is nothing but that slot. Shuffling
leaves a reader of the snapshot with offsets that no longer line up with the
source, or with the other classes of the program, and costs nothing at runtime.

The one thing the order decides besides the layout is left alone: a constructor
runs the initializers the instance fields declare in declaration order, so the
fields whose initializer can tell keep their order relative to one another. On a
release snapshot none of them can - the front end's type flow analysis has
already hoisted every such initializer into the constructors, and what a field
still holds is a constant the VM stores into the instance directly - but the
pass checks rather than assumes. A `dart:ffi` `Struct` or `Union` is skipped
outright, because there the field order is the ABI the native side on the other
end expects.

- String obfuscation

Every string literal of the selected libraries is replaced by
`_sN ??= _d(offset, length, key)`: a static variable per distinct string, filled
on first use by the one decrypt function the snapshot carries. The strings
themselves are deduplicated and packed into a single blob - overlapping where
one string occurs inside another, so there are no boundaries left to recover -
and the blob is encrypted with a rolling key where the key for the next code
unit depends on the one just decrypted.

Strings that have to stay constant for the snapshot to be valid are left alone:
annotations, default parameter values, `case 'x':` expressions, `const` fields
and anything inside a `const` object, such as the text of a `const Text('...')`
widget.

## Planned Features

- Control flow obfuscation

## Layout

| Path                      |                                                                      |
| ------------------------- | -------------------------------------------------------------------- |
| `bin/flutter_shield.dart` | The tool the patched build step runs, one snapshot in, one out.      |
| `lib/pass.dart`           | The pass abstraction: what a pass is handed and what it may rewrite. |
| `lib/package_filter.dart` | Which libraries are the author's own code.                           |
| `lib/shield.dart`         | Runs the passes over a snapshot.                                     |
| `lib/snapshot.dart`       | Reading and writing snapshots without losing the VM's metadata.      |
| `lib/ast_builder.dart`    | The kernel expressions the passes generate.                          |
| `lib/passes/`             | The passes themselves.                                               |
| `scripts/patch.sh`        | Fetches and patches the flutter SDK in `flutter_bin`.                |
| `scripts/make_patch.sh`   | Regenerates `patch.diff` from the changes in `flutter_bin`.          |
| `scripts/vendor.sh`       | Vendors `package:kernel` and `package:vm` from the Dart SDK.         |

`package:kernel` and `package:vm` are not published on pub.dev and the copies in
the Dart SDK repository are workspace members, so they cannot be git
dependencies either; `scripts/vendor.sh` copies them into `kernel_pkg` and
`vm_pkg` and they must match the Dart SDK that ships with the pinned flutter
version.
