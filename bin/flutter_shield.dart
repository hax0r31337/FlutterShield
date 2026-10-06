import 'dart:io';

import 'package:flutter_shield/flutter_shield.dart';
import 'package:kernel/ast.dart';

/// Regex of the packages to obfuscate, as described in the README.
const String packageVariable = 'FS_PACKAGE';

/// Optional fixed cipher seed, for a reproducible build.
const String seedVariable = 'FS_SEED';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln('usage: flutter_shield <input.dill> <output.dill>');
    stderr.writeln(
      '  $packageVariable  regex matched against package names, selects what to obfuscate',
    );
    stderr.writeln(
      '  $seedVariable     fixed cipher seed, random per build when unset',
    );
    exit(64);
  }
  final input = File(arguments[0]);
  final output = File(arguments[1]);

  if (!input.existsSync()) {
    stderr.writeln('flutter_shield: input dill not found: ${input.path}');
    exit(66);
  }

  final PackageFilter filter;
  try {
    filter = PackageFilter.parse(Platform.environment[packageVariable]);
  } on FormatException catch (error) {
    stderr.writeln('flutter_shield: $packageVariable: ${error.message}');
    exit(64);
  }

  final String? rawSeed = Platform.environment[seedVariable];
  final int? seed = rawSeed == null ? null : int.tryParse(rawSeed);
  if (rawSeed != null && seed == null) {
    stderr.writeln('flutter_shield: $seedVariable is not an integer: $rawSeed');
    exit(64);
  }

  output.parent.createSync(recursive: true);

  // Nothing selected: hand the snapshot through untouched rather than
  // round tripping it through the kernel reader and writer for nothing.
  if (filter.selectsNothing) {
    stdout.writeln(
      'flutter_shield: $packageVariable is not set, passing the snapshot through',
    );
    input.copySync(output.path);
    return;
  }

  final Component component = readSnapshot(input.path);
  Shield(
    filter: filter,
    passes: <ObfuscationPass>[StringEncryptionPass(seed: seed)],
    logger: (String message) => stdout.writeln('flutter_shield: $message'),
  ).harden(component);

  await writeSnapshot(component, output.path);
}
