import 'dart:math';

import 'package:kernel/ast.dart';

import 'package_filter.dart';
import 'pass.dart';
import 'passes/field_shuffle.dart';
import 'passes/string_encryption.dart';

/// Runs obfuscation passes over the kernel snapshot of an application.
class Shield {
  Shield({
    required this.filter,
    List<ObfuscationPass>? passes,
    this.random,
    void Function(String message)? logger,
  }) : passes = passes ?? passesWithSeed(null),
       _logger = logger ?? print;

  /// Every pass the tool knows, in the order they have to run in, each handed
  /// [seed] - null for the randomness of the run itself.
  ///
  /// Field shuffling goes first because it reads the field initializers to
  /// decide what it may move, and string encryption rewrites a plain
  /// `final x = 'y'` into a call. Run the other way around, every such field
  /// would look like one whose initializer has to keep its place.
  static List<ObfuscationPass> passesWithSeed(int? seed) => <ObfuscationPass>[
    FieldShufflePass(seed: seed),
    StringEncryptionPass(seed: seed),
  ];

  /// Which libraries of the snapshot are the author's own code.
  final PackageFilter filter;

  final List<ObfuscationPass> passes;

  final Random? random;

  final void Function(String message) _logger;

  /// Rewrites [component] in place, and reports whether anything ran.
  bool harden(Component component) {
    if (filter.selectsNothing) {
      _logger('no package filter set, nothing to do');
      return false;
    }
    if (!component.libraries.any(
      (Library library) => library.importUri.toString() == 'dart:core',
    )) {
      throw StateError(
        'the snapshot does not have the platform linked into it, which the '
        'generated code needs to reference dart:core',
      );
    }

    final context = PassContext(
      component: component,
      filter: filter,
      random: random,
      logger: _logger,
    );
    if (context.libraries.isEmpty) {
      _logger(
        '${filter.pattern} matched none of the libraries in the snapshot',
      );
      return false;
    }

    _logger(
      'hardening ${context.libraries.length} libraries matching ${filter.pattern}',
    );
    for (final ObfuscationPass pass in passes) {
      pass.run(context);
    }
    return true;
  }
}
