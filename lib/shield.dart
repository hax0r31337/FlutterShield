import 'dart:math';

import 'package:kernel/ast.dart';

import 'package_filter.dart';
import 'pass.dart';
import 'passes/field_shuffle.dart';
import 'passes/path_scrub.dart';
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
  /// Path scrubbing goes first because it is independent of the others: it
  /// renames libraries no other pass is allowed to touch, and it is done
  /// before any pass has generated a support library to rename.
  ///
  /// Field shuffling goes before string encryption because it reads the field
  /// initializers to decide what it may move, and string encryption rewrites
  /// a plain `final x = 'y'` into a call. Run the other way around, every such
  /// field would look like one whose initializer has to keep its place.
  static List<ObfuscationPass> passesWithSeed(int? seed) => <ObfuscationPass>[
    const PathScrubPass(),
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

    // An unscoped pass rewrites what the build put in the snapshot rather
    // than the author's own code, so it has work to do whether or not a
    // package was selected; a scoped pass does not.
    final bool selectedNothing = context.libraries.isEmpty;
    if (selectedNothing) {
      _logger(
        filter.selectsNothing
            ? 'no package filter set, running the unscoped passes only'
            : '${filter.pattern} matched none of the libraries in the '
                  'snapshot, running the unscoped passes only',
      );
    } else {
      _logger(
        'hardening ${context.libraries.length} libraries matching ${filter.pattern}',
      );
    }

    final List<ObfuscationPass> selected = selectedNothing
        ? passes.where((ObfuscationPass pass) => !pass.scoped).toList()
        : passes;
    if (selected.isEmpty) {
      return false;
    }
    for (final ObfuscationPass pass in selected) {
      pass.run(context);
    }
    return true;
  }
}
