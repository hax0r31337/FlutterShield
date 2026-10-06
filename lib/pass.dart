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

/// Returns the passes of [available] that [names] selects, in the order
/// [available] lists them.
///
/// [names] is the value of `FS_PASSES`, a comma separated list of
/// [ObfuscationPass.name]s. A missing or blank value selects every pass, so a
/// build that does not care which passes exist gets all of them; the order the
/// passes run in is the one [available] fixes either way, because passes are
/// not independent of one another.
///
/// Throws a [FormatException] if [names] holds an entry that is not the name of
/// an available pass, or no entry at all - running nothing while the build
/// thinks it asked for something is the failure this is here to prevent.
List<ObfuscationPass> selectPasses(
  List<ObfuscationPass> available,
  String? names,
) {
  if (names == null || names.trim().isEmpty) {
    return List<ObfuscationPass>.unmodifiable(available);
  }

  final selected = <String>{
    for (final String entry in names.split(','))
      if (entry.trim().isNotEmpty) entry.trim(),
  };
  final String known = available
      .map((ObfuscationPass pass) => pass.name)
      .join(', ');
  if (selected.isEmpty) {
    throw FormatException('names no pass, known passes are $known', names);
  }

  final List<String> unknown =
      selected
          .where(
            (String name) =>
                !available.any((ObfuscationPass pass) => pass.name == name),
          )
          .toList()
        ..sort();
  if (unknown.isNotEmpty) {
    throw FormatException(
      'unknown pass${unknown.length == 1 ? '' : 'es'} ${unknown.join(', ')}, '
      'known passes are $known',
      names,
    );
  }

  return List<ObfuscationPass>.unmodifiable(
    available.where((ObfuscationPass pass) => selected.contains(pass.name)),
  );
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
  /// Both URIs of the library are derived from [name] and made unique: a
  /// snapshot cannot hold two libraries under the same import URI, nor two
  /// sources under the same file URI.
  Library addSupportLibrary(String name) {
    final taken = <Uri>{
      for (final Library library in component.libraries) ...<Uri>[
        library.importUri,
        library.fileUri,
      ],
      ...component.uriToSource.keys,
    };
    String unique = name;
    for (
      int suffix = 1;
      taken.contains(_importUriFor(unique)) ||
          taken.contains(_fileUriFor(unique));
      suffix++
    ) {
      unique = '$name$suffix';
    }

    final library = Library(
      _importUriFor(unique),
      fileUri: _fileUriFor(unique),
      name: name,
    )..fileOffset = 0;
    component.libraries.add(library);
    library.parent = component;
    registerGeneratedLibrary(component, library);
    return library;
  }

  /// The URI a generated library is imported under.
  ///
  /// Nothing resolves it - the passes reference the generated members
  /// directly - it only has to be distinct from every other library of the
  /// snapshot, and to say where the code came from when it shows up in a
  /// stack trace or an obfuscation map.
  static Uri _importUriFor(String name) =>
      Uri.parse('package:flutter_shield/$name.dart');

  /// The URI of the source a generated library pretends to come from.
  ///
  /// There is no such file, and the snapshot carries an empty source for it,
  /// but the URI still has to be one the AOT compiler can turn back into a
  /// path: `--split-debug-info` makes `gen_snapshot` resolve the file URI of
  /// every library it emits code for, and it aborts the build on a URI whose
  /// root it does not know - `file:///`, `org-dartlang-sdk:///` and
  /// `google3:///` are all of them, which rules out the `package:` URI the
  /// library is imported under. The root is fixed rather than taken from the
  /// build machine, so two builds of the same sources still agree.
  static Uri _fileUriFor(String name) =>
      Uri.parse('file:///flutter_shield/$name.dart');
}
