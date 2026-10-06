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
      '  $packageVariable  required, regex matched against package names, selects what to obfuscate',
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

  // A build that silently ships unobfuscated is worse than one that fails, so
  // a missing filter is an error rather than a pass through.
  final String? rawPattern = Platform.environment[packageVariable];
  if (rawPattern == null || rawPattern.isEmpty) {
    stderr.writeln(
      'flutter_shield: $packageVariable is not set, refusing to build an '
      'unobfuscated snapshot',
    );
    stderr.writeln(
      '  pass it as a regex over package names, for example '
      '$packageVariable=^my_app\$',
    );
    exit(64);
  }

  final PackageFilter filter;
  try {
    filter = PackageFilter.matching(rawPattern);
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

  final Component component = readSnapshot(input.path);
  Shield(
    filter: filter,
    passes: <ObfuscationPass>[StringEncryptionPass(seed: seed)],
    logger: (String message) => stdout.writeln('flutter_shield: $message'),
  ).harden(component);

  await writeSnapshot(component, output.path);
}
