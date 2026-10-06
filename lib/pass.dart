import 'dart:math';

import 'package:kernel/ast.dart';
import 'package:kernel/core_types.dart';

import 'ast_builder.dart';
import 'package_filter.dart';
import 'snapshot.dart';

/// A single obfuscation step over the kernel snapshot of an application.
///
/// A pass is handed the whole [Component] - a release snapshot has the
/// platform libraries linked into it - but may only rewrite the code of
/// [PassContext.libraries], the libraries the package filter selected.
/// Anything a pass generates goes into a support library of its own, see
/// [PassContext.addSupportLibrary].
abstract class ObfuscationPass {
  const ObfuscationPass();

  /// Stable identifier of this pass, used in logs and to select passes by
  /// name.
  String get name;

  /// Rewrites the component of [context] in place.
  void run(PassContext context);
}

/// The component under obfuscation, plus the shared state every pass needs.
class PassContext {
  PassContext({
    required this.component,
    required this.filter,
    Random? random,
    void Function(String message)? logger,
  }) : random = random ?? Random.secure(),
       _logger = logger ?? print,
       libraries = List<Library>.unmodifiable(
         component.libraries.where(filter.allows),
       );

  /// The snapshot being hardened.
  final Component component;

  /// Which libraries of [component] are the author's own code.
  final PackageFilter filter;

  /// The libraries passes may rewrite.
  ///
  /// Fixed when the context is created, so support libraries added by one pass
  /// are never obfuscated by the next.
  final List<Library> libraries;

  /// Randomness for passes that need it, such as cipher keys.
  final Random random;

  final void Function(String message) _logger;

  late final CoreTypes coreTypes = CoreTypes(component);

  late final AstBuilder ast = AstBuilder(coreTypes);

  void log(String message) => _logger(message);

  /// Adds an empty library to [component] for a pass to generate code into.
  ///
  /// The import URI is derived from [name] and made unique, since a snapshot
  /// cannot hold two libraries under the same URI.
  Library addSupportLibrary(String name) {
    final Set<Uri> taken = component.libraries
        .map((Library library) => library.importUri)
        .toSet();
    Uri uri = Uri.parse('package:flutter_shield/$name.dart');
    for (int suffix = 1; taken.contains(uri); suffix++) {
      uri = Uri.parse('package:flutter_shield/$name$suffix.dart');
    }

    final library = Library(uri, fileUri: uri, name: name)..fileOffset = 0;
    component.libraries.add(library);
    library.parent = component;
    registerGeneratedLibrary(component, library);
    return library;
  }
}
