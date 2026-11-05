import 'dart:typed_data';

import 'package:kernel/ast.dart';
import 'package:vm/metadata/loading_units.dart';
import 'package:vm/metadata/obfuscation_prohibitions.dart';

import '../pass.dart';
import '../snapshot.dart';

/// Replaces the absolute paths of the build machine that the front end leaves
/// in the snapshot with fixed synthetic ones.
///
/// Every library of an application is named by a `package:` URI, which says
/// nothing about where it was built, with one exception: a library the build
/// generates outside `lib/` has no package URI to be named by, so the front
/// end names it by its path on the build box. Flutter generates exactly one
/// such library today, `.dart_tool/flutter_build/dart_plugin_registrant.dart`,
/// which is written whenever a plugin of the app declares a `dartPluginClass`
/// for the target platform. The absolute path of that file survives
/// `--obfuscate`, `--split-debug-info` and `strip`, and in a release build of
/// an app with any such plugin it is the only build path left in the shipped
/// `libapp.so`.
///
/// It survives because `--obfuscate` renames symbols and this is a library
/// URL, which the VM keeps: the embedder reads the const
/// `dartPluginRegistrantLibrary` of `package:flutter`, looks the library up
/// *by that URL*, and invokes `_PluginRegistrant.register()` on it. The
/// obfuscator is told as much - the annotator of
/// `package:vm/transformations/obfuscation_prohibitions_annotator.dart` adds
/// the import URI of the enclosing library of every `vm:entry-point` member to
/// the protected names, so `gen_snapshot --save-obfuscation-map` reports the
/// path mapped to itself.
///
/// So the URI cannot be dropped, only replaced, and replaced in every place
/// at once - the library it names, the nodes inside it, the const the embedder
/// reads, and the protected names - or the lookup stops finding it and the
/// plugins of a release build silently stop registering. That is what this
/// pass does, to a URI under [scrubbedRoot] that reveals nothing but the file
/// name and is the same on every machine.
///
/// The pass is not scoped to the package filter: what it rewrites is not the
/// author's code but what the build put in the snapshot alongside it.
///
/// Two kinds of absolute path are deliberately left alone, because neither
/// reaches the shipped snapshot. The `fileUri` of a `package:` library, which
/// is where the file sat on the build box, and with it the keys of
/// [Component.uriToSource]: those feed the debugging information, which
/// `--split-debug-info` writes to a separate file the app does not carry, and
/// rewriting them would only corrupt the symbols the author keeps to read
/// their own crash reports. `gen_snapshot` drops the script URLs of a release
/// snapshot either way.
class PathScrubPass extends ObfuscationPass {
  const PathScrubPass();

  /// The directory the scrubbed URIs are rooted at.
  ///
  /// It has to be a root `gen_snapshot` can resolve back into a path, the same
  /// constraint the support libraries of [PassContext.addSupportLibrary] are
  /// under, and the root is fixed rather than taken from the build machine so
  /// that two builds of the same sources still agree.
  static const String scrubbedRoot = 'file:///flutter_shield';

  @override
  String get name => 'path-scrub';

  @override
  bool get scoped => false;

  @override
  void run(PassContext context) {
    final Component component = context.component;

    // Sorted, so that a build repeated on the same sources hands out the same
    // scrubbed URIs even though the library order of the snapshot is not
    // something this pass should have to rely on.
    final List<Library> loose =
        component.libraries
            .where((Library library) => library.importUri.isScheme('file'))
            .toList()
          ..sort(
            (Library a, Library b) =>
                a.importUri.toString().compareTo(b.importUri.toString()),
          );
    if (loose.isEmpty) {
      context.log('path-scrub: no library is named by a path');
      return;
    }

    final taken = <Uri>{
      for (final Library library in component.libraries) ...<Uri>[
        library.importUri,
        library.fileUri,
      ],
      ...component.uriToSource.keys,
    };
    final renames = <_Rename>[];
    final rewrites = <Uri, Uri>{};
    for (final Library library in loose) {
      // A library does not collide with itself, so running the tool twice
      // over the same snapshot hands out the same URIs the first run did
      // rather than suffixing them again.
      final Uri scrubbed = _scrubbed(
        library.importUri,
        taken.difference(<Uri>{library.importUri, library.fileUri}),
      );
      taken.add(scrubbed);
      renames.add(
        _Rename(
          library: library,
          importUri: library.importUri,
          fileUri: library.fileUri,
          scrubbed: scrubbed,
        ),
      );
      rewrites[library.importUri] = scrubbed;
      rewrites.putIfAbsent(library.fileUri, () => scrubbed);
    }

    // The walk comes before the renames, and not only because it is what
    // rewrites the URIs the nodes carry. A snapshot is read lazily - the body
    // of a class or of a function is deserialized when it is first asked for,
    // and the references in it are resolved through the canonical names that
    // were in the tree when the snapshot was read. Deserializing after a
    // rename has taken those names out resolves them to nothing, and the
    // invocation of `_PluginRegistrant.register` in the library being renamed
    // is exactly such a reference. Walking the component first forces the
    // reader to finish while the names it needs are still there.
    final sites = _ScrubbedSites(rewrites);
    component.accept(sites);

    for (final _Rename rename in renames) {
      _rename(component, rename);
      context.log('path-scrub: ${rename.importUri} is now ${rename.scrubbed}');
    }

    final int protected = _protect(component, rewrites);

    // The type flow analysis records the value of an expression it found to be
    // constant, and `gen_snapshot` folds that recorded value back in, which
    // would put the old path straight back into the snapshot.
    dropRecordedStringConstants(component, <String>{
      for (final Uri uri in rewrites.keys) uri.toString(),
    });

    context.log(
      'path-scrub: ${loose.length} libraries renamed, '
      '${sites.fileUris} source references, '
      '${sites.constants + sites.literals} string values and '
      '$protected protected names rewritten',
    );
  }

  /// A URI under [scrubbedRoot] that stands in for [uri] and is none of
  /// [taken].
  ///
  /// Only the file name of [uri] is kept. It is the one part of the path that
  /// says what the library is rather than where it was built, and keeping it
  /// is what makes an obfuscation map or a stack trace readable at all.
  static Uri _scrubbed(Uri uri, Set<Uri> taken) {
    final String name = uri.pathSegments.isEmpty
        ? 'library.dart'
        : uri.pathSegments.last;
    Uri candidate = Uri.parse('$scrubbedRoot/$name');
    for (int suffix = 1; taken.contains(candidate); suffix++) {
      candidate = Uri.parse('$scrubbedRoot/$suffix/$name');
    }
    return candidate;
  }

  /// Carries out [rename], along with everything in the snapshot that is
  /// keyed by the URI of a library rather than by a node of it.
  static void _rename(Component component, _Rename rename) {
    final Library library = rename.library;
    final Uri importUri = rename.importUri;
    final Uri fileUri = rename.fileUri;
    final Uri scrubbed = rename.scrubbed;

    // The canonical name of a library *is* its import URI, and the names of
    // the nodes under it hang off that, so the subtree has to be rebuilt
    // rather than renamed. Nothing outside it can point into it: a library
    // named by a path is one no other library of the snapshot is able to
    // import.
    //
    // A class whose members are already bound is left alone by
    // `ensureCanonicalNames` unless it is marked dirty, which is how
    // [Component.unbindCanonicalNames] drives the same rebuild.
    for (final Class node in library.classes) {
      node.dirty = true;
    }
    library.reference.canonicalName?.unbindAll();
    component.root.removeChild(importUri.toString());

    library.importUri = scrubbed;
    library.fileUri = scrubbed;

    // Every library needs a source entry, if only an empty one, for the URI
    // the AOT compiler puts in its debugging information - and the entry
    // carries the URIs a second time, so it is rebuilt rather than moved.
    final Source? source = component.uriToSource.remove(fileUri);
    component.uriToSource[scrubbed] = source == null
        ? Source(<int>[0], Uint8List(0), scrubbed, scrubbed)
        : (Source(source.lineStarts, source.source, scrubbed, scrubbed)
            ..constantCoverageConstructors = source.constantCoverageConstructors
            ..cachedText = source.cachedText);

    _renameInLoadingUnits(component, importUri, scrubbed);
    component.computeCanonicalNamesForLibrary(library);
  }

  /// Replaces [from] with [to] in the loading unit that lists it.
  ///
  /// Deferred loading splits the libraries over loading units, and a unit
  /// holds the import URI of each of its libraries as a string, which no
  /// rename of the library itself reaches.
  static void _renameInLoadingUnits(Component component, Uri from, Uri to) {
    final repository =
        component.metadata[LoadingUnitsMetadataRepository.repositoryTag]
            as LoadingUnitsMetadataRepository?;
    final LoadingUnitsMetadata? metadata = repository?.mapping[component];
    if (metadata == null) {
      return;
    }
    final String fromUri = from.toString();
    final String toUri = to.toString();
    for (final LoadingUnit unit in metadata.loadingUnits) {
      if (unit.libraryUris.remove(fromUri)) {
        unit.libraryUris.add(toUri);
      }
    }
  }

  /// Carries the obfuscation prohibitions of the renamed libraries over to
  /// their new URIs, and reports how many were moved.
  ///
  /// A protected name tells `gen_snapshot` not to rename something, and the
  /// URI of a library holding a `vm:entry-point` member is one of them. The
  /// old URI has to go - the list is a set of strings the snapshot carries, so
  /// leaving it there would leak the path this pass is here to remove - and
  /// the new one has to take its place, or the obfuscator renames the library
  /// the embedder is about to look up by name.
  static int _protect(Component component, Map<Uri, Uri> rewrites) {
    final repository =
        component.metadata[ObfuscationProhibitionsMetadataRepository
                .repositoryTag]
            as ObfuscationProhibitionsMetadataRepository?;
    final ObfuscationProhibitionsMetadata? metadata =
        repository?.mapping[component];
    if (metadata == null) {
      return 0;
    }
    int moved = 0;
    for (final MapEntry<Uri, Uri> rewrite in rewrites.entries) {
      if (metadata.protectedNames.remove(rewrite.key.toString())) {
        metadata.protectedNames.add(rewrite.value.toString());
        moved++;
      }
    }
    return moved;
  }
}

/// A library that is to be renamed, and the URIs it had before the walk that
/// rewrites the nodes under it got to them.
class _Rename {
  const _Rename({
    required this.library,
    required this.importUri,
    required this.fileUri,
    required this.scrubbed,
  });

  final Library library;
  final Uri importUri;
  final Uri fileUri;
  final Uri scrubbed;
}

/// Rewrites every reference to a renamed URI that sits in the tree rather than
/// in a table of the component.
///
/// There are three of them. The `fileUri` of a node, which is how a class or a
/// member of a library named by a path carries that path a second time; a
/// string constant whose value is such a URI, which is how the embedder is
/// told where to find the plugin registrant; and a plain string literal of the
/// same value, which is the shape the same code has before the type flow
/// analysis turns its constants into constant expressions.
class _ScrubbedSites extends RecursiveVisitor {
  _ScrubbedSites(this.uris)
    : strings = <String, String>{
        for (final MapEntry<Uri, Uri> rewrite in uris.entries)
          rewrite.key.toString(): rewrite.value.toString(),
      };

  final Map<Uri, Uri> uris;
  final Map<String, String> strings;

  int fileUris = 0;
  int constants = 0;
  int literals = 0;

  @override
  void defaultNode(Node node) {
    // A node can be both - `FileUriConstantExpression` is a constant
    // expression that carries a file URI of its own - so these are not
    // alternatives.
    if (node is FileUriNode) {
      final Uri? scrubbed = uris[node.fileUri];
      if (scrubbed != null) {
        node.fileUri = scrubbed;
        fileUris++;
      }
    }
    if (node is ConstantExpression) {
      final Constant? scrubbed = _scrubbedConstant(node.constant);
      if (scrubbed != null) {
        node.constant = scrubbed;
        constants++;
      }
    } else if (node is StringLiteral) {
      final String? scrubbed = strings[node.value];
      if (scrubbed != null) {
        node.value = scrubbed;
        literals++;
      }
    }
    super.defaultNode(node);
  }

  /// [constant] with every renamed URI in it replaced, or null if there is
  /// none in it.
  ///
  /// Constants are immutable, so a changed one is rebuilt. Only the kinds a
  /// string can be reached through are walked; a kind this does not know is
  /// left alone, which keeps the snapshot valid and would at worst leave a
  /// path in a constant no build has been seen to produce.
  Constant? _scrubbedConstant(Constant constant) {
    switch (constant) {
      case StringConstant():
        final String? scrubbed = strings[constant.value];
        return scrubbed == null ? null : StringConstant(scrubbed);
      case ListConstant():
        final List<Constant>? entries = _scrubbedEntries(constant.entries);
        return entries == null
            ? null
            : ListConstant(constant.typeArgument, entries);
      case SetConstant():
        final List<Constant>? entries = _scrubbedEntries(constant.entries);
        return entries == null
            ? null
            : SetConstant(constant.typeArgument, entries);
      case MapConstant():
        var changed = false;
        final entries = <ConstantMapEntry>[];
        for (final ConstantMapEntry entry in constant.entries) {
          final Constant? key = _scrubbedConstant(entry.key);
          final Constant? value = _scrubbedConstant(entry.value);
          changed |= key != null || value != null;
          entries.add(ConstantMapEntry(key ?? entry.key, value ?? entry.value));
        }
        return changed
            ? MapConstant(constant.keyType, constant.valueType, entries)
            : null;
      case RecordConstant():
        final List<Constant>? positional = _scrubbedEntries(
          constant.positional,
        );
        final Map<String, Constant>? named = _scrubbedFields(constant.named);
        return positional == null && named == null
            ? null
            : RecordConstant(
                positional ?? constant.positional,
                named ?? constant.named,
                constant.recordType,
              );
      case InstanceConstant():
        final Map<Reference, Constant>? fieldValues = _scrubbedFields(
          constant.fieldValues,
        );
        return fieldValues == null
            ? null
            : InstanceConstant(
                constant.classReference,
                constant.typeArguments,
                fieldValues,
              );
      default:
        return null;
    }
  }

  /// [entries] with every renamed URI in them replaced, or null if there is
  /// none in any of them.
  List<Constant>? _scrubbedEntries(List<Constant> entries) {
    var changed = false;
    final scrubbed = <Constant>[];
    for (final Constant entry in entries) {
      final Constant? value = _scrubbedConstant(entry);
      changed |= value != null;
      scrubbed.add(value ?? entry);
    }
    return changed ? scrubbed : null;
  }

  /// [fields] with every renamed URI in them replaced, or null if there is
  /// none in any of them.
  Map<K, Constant>? _scrubbedFields<K>(Map<K, Constant> fields) {
    var changed = false;
    final scrubbed = <K, Constant>{};
    for (final MapEntry<K, Constant> field in fields.entries) {
      final Constant? value = _scrubbedConstant(field.value);
      changed |= value != null;
      scrubbed[field.key] = value ?? field.value;
    }
    return changed ? scrubbed : null;
  }
}
