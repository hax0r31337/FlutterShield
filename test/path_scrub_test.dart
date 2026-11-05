@Timeout(Duration(minutes: 5))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_shield/flutter_shield.dart';
import 'package:kernel/kernel.dart';
import 'package:kernel/target/targets.dart';
import 'package:kernel/verifier.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:vm/metadata/loading_units.dart';
import 'package:vm/metadata/obfuscation_prohibitions.dart';

/// The URI roots `gen_snapshot` knows how to turn back into a source path,
/// from `runtime/vm/debug_info.cc` of the Dart SDK.
const List<String> resolvableRoots = <String>[
  'file:///',
  'org-dartlang-sdk:///',
  'google3:///',
];

/// A loose library of an app, the shape the generated plugin registrant has:
/// a class the embedder looks up by name, in a library named by its path on
/// the build box.
const String registrantFixture = r'''
@pragma('vm:entry-point')
class _PluginRegistrant {
  @pragma('vm:entry-point')
  static void register() {
    print('registered');
  }
}

void main() {
  _PluginRegistrant.register();
}
''';

PassContext contextOf(Component component) => PassContext(
  component: component,
  filter: PackageFilter.parse(r'^my_app$'),
  logger: (String message) {},
);

Library libraryIn(Component component, String importUri, {String? fileUri}) {
  final Uri uri = Uri.parse(importUri);
  final Uri file = fileUri == null ? uri : Uri.parse(fileUri);
  final library = Library(uri, fileUri: file);
  component.libraries.add(library);
  library.parent = component;
  component.uriToSource[file] = Source(<int>[0], Uint8List(0), uri, file);
  return library;
}

/// A component holding one library named by [path], with a class and a method
/// in it, plus a `package:` library holding the const the embedder reads.
Component componentNamedBy(String path, {String? constValue}) {
  final component = Component();
  final Library loose = libraryIn(component, path);
  loose.addClass(
    Class(
      name: '_PluginRegistrant',
      fileUri: loose.fileUri,
      procedures: <Procedure>[
        Procedure(
          Name('register', loose),
          ProcedureKind.Method,
          FunctionNode(EmptyStatement()),
          fileUri: loose.fileUri,
          isStatic: true,
        ),
      ],
    ),
  );

  final Library flutter = libraryIn(
    component,
    'package:flutter/src/dart_plugin_registrant.dart',
    fileUri: 'file:///home/someone/flutter/packages/flutter/lib/src/f.dart',
  );
  flutter.addField(
    Field.immutable(
      Name('dartPluginRegistrantLibrary', flutter),
      fileUri: flutter.fileUri,
      isStatic: true,
      isConst: true,
      initializer: ConstantExpression(
        StringConstant(constValue ?? path),
        const DynamicType(),
      ),
    ),
  );
  return component;
}

Field fieldNamed(Component component, String name) => component.libraries
    .expand((Library library) => library.fields)
    .firstWhere((Field field) => field.name.text == name);

String valueOf(Field field) =>
    ((field.initializer! as ConstantExpression).constant as StringConstant)
        .value;

List<Uri> fileUrisOf(Library library) => <Uri>[
  library.fileUri,
  for (final Class node in library.classes) ...<Uri>[
    node.fileUri,
    for (final Procedure procedure in node.procedures) procedure.fileUri,
  ],
];

void main() {
  const String buildPath =
      'file:///home/someone/app/.dart_tool/flutter_build/'
      'dart_plugin_registrant.dart';

  group('synthetic components', () {
    test('a library named by a path is renamed to a fixed URI', () {
      final Component component = componentNamedBy(buildPath);
      const PathScrubPass().run(contextOf(component));

      final Library scrubbed = component.libraries.first;
      expect(
        scrubbed.importUri.toString(),
        'file:///flutter_shield/dart_plugin_registrant.dart',
      );
      expect(scrubbed.fileUri, scrubbed.importUri);
      expect(
        resolvableRoots.any(scrubbed.fileUri.toString().startsWith),
        isTrue,
        reason: 'gen_snapshot cannot resolve ${scrubbed.fileUri}',
      );
    });

    test('the nodes of a renamed library stop carrying the path', () {
      final Component component = componentNamedBy(buildPath);
      expect(
        fileUrisOf(component.libraries.first).map((Uri uri) => uri.toString()),
        everyElement(buildPath),
        reason: 'the fixture should start out carrying the path everywhere',
      );

      const PathScrubPass().run(contextOf(component));

      expect(
        fileUrisOf(component.libraries.first).map((Uri uri) => uri.toString()),
        everyElement('file:///flutter_shield/dart_plugin_registrant.dart'),
      );
    });

    test('the source entry is moved to the new URI', () {
      final Component component = componentNamedBy(buildPath);
      const PathScrubPass().run(contextOf(component));

      final Library scrubbed = component.libraries.first;
      expect(component.uriToSource.keys, isNot(contains(Uri.parse(buildPath))));
      expect(component.uriToSource.keys, contains(scrubbed.fileUri));
      // The entry carries the URIs a second time, so moving the key is not
      // enough.
      final Source source = component.uriToSource[scrubbed.fileUri]!;
      expect(source.importUri, scrubbed.importUri);
      expect(source.fileUri, scrubbed.fileUri);
    });

    test('the const the embedder reads is rewritten with the library', () {
      final Component component = componentNamedBy(buildPath);
      const PathScrubPass().run(contextOf(component));

      // The embedder reads this const and looks the library up by the value,
      // so the two have to keep saying the same thing.
      expect(
        valueOf(fieldNamed(component, 'dartPluginRegistrantLibrary')),
        component.libraries.first.importUri.toString(),
      );
    });

    test('a string literal of the same value is rewritten too', () {
      // Before the type flow analysis the same const is a plain literal.
      final Component component = componentNamedBy(buildPath);
      final Library flutter = component.libraries.last;
      flutter.addField(
        Field.immutable(
          Name('asLiteral', flutter),
          fileUri: flutter.fileUri,
          isStatic: true,
          initializer: StringLiteral(buildPath),
        ),
      );

      const PathScrubPass().run(contextOf(component));

      expect(
        (fieldNamed(component, 'asLiteral').initializer! as StringLiteral)
            .value,
        component.libraries.first.importUri.toString(),
      );
    });

    test('a string that is not a renamed URI is left alone', () {
      final Component component = componentNamedBy(
        buildPath,
        constValue: 'file:///home/someone/app/lib/main.dart',
      );
      const PathScrubPass().run(contextOf(component));

      expect(
        valueOf(fieldNamed(component, 'dartPluginRegistrantLibrary')),
        'file:///home/someone/app/lib/main.dart',
      );
    });

    test('the protected name moves with the library', () {
      final Component component = componentNamedBy(buildPath);
      final repository = ObfuscationProhibitionsMetadataRepository();
      component.addMetadataRepository(repository);
      final metadata = ObfuscationProhibitionsMetadata();
      metadata.protectedNames.addAll(<String>[
        buildPath,
        'package:flutter/src/dart_plugin_registrant.dart',
        'register',
      ]);
      repository.mapping[component] = metadata;

      const PathScrubPass().run(contextOf(component));

      // Dropping it would leak the path the pass is here to remove; losing it
      // would let the obfuscator rename the library the embedder looks up.
      expect(metadata.protectedNames, isNot(contains(buildPath)));
      expect(
        metadata.protectedNames,
        contains(component.libraries.first.importUri.toString()),
      );
      expect(
        metadata.protectedNames,
        containsAll(<String>[
          'package:flutter/src/dart_plugin_registrant.dart',
          'register',
        ]),
      );
    });

    test('the loading unit follows the rename', () {
      final Component component = componentNamedBy(buildPath);
      final repository = LoadingUnitsMetadataRepository();
      component.addMetadataRepository(repository);
      repository.mapping[component] = LoadingUnitsMetadata(<LoadingUnit>[
        LoadingUnit(1, 0, <String>[buildPath, 'package:my_app/main.dart']),
      ]);

      const PathScrubPass().run(contextOf(component));

      final List<String> uris =
          repository.mapping[component]!.loadingUnits.single.libraryUris;
      expect(uris, isNot(contains(buildPath)));
      expect(uris, contains(component.libraries.first.importUri.toString()));
      expect(uris, contains('package:my_app/main.dart'));
    });

    test('the path a package library was built from is left alone', () {
      // It is the file URI of a `package:` library, which feeds the debugging
      // information `--split-debug-info` keeps out of the app, and rewriting
      // it would only corrupt the symbols the author keeps.
      final Component component = componentNamedBy(buildPath);
      final Uri before = component.libraries.last.fileUri;

      const PathScrubPass().run(contextOf(component));

      expect(component.libraries.last.fileUri, before);
      expect(component.libraries.last.importUri.isScheme('package'), isTrue);
    });

    test('two libraries of the same file name do not collide', () {
      final Component component = componentNamedBy(buildPath);
      libraryIn(component, 'file:///elsewhere/dart_plugin_registrant.dart');

      const PathScrubPass().run(contextOf(component));

      final List<Library> scrubbed = component.libraries
          .where((Library library) => library.importUri.isScheme('file'))
          .toList();
      expect(scrubbed, hasLength(2));
      expect(scrubbed[0].importUri, isNot(scrubbed[1].importUri));
      expect(scrubbed[0].fileUri, isNot(scrubbed[1].fileUri));
      expect(
        scrubbed.map((Library library) => library.importUri.toString()),
        everyElement(startsWith(PathScrubPass.scrubbedRoot)),
      );
    });

    test('a snapshot with no library named by a path is left alone', () {
      final component = Component();
      libraryIn(component, 'package:my_app/main.dart');
      final logs = <String>[];
      const PathScrubPass().run(
        PassContext(
          component: component,
          filter: PackageFilter.parse(r'^my_app$'),
          logger: logs.add,
        ),
      );

      expect(logs.join('\n'), contains('no library is named by a path'));
      expect(
        component.libraries.single.importUri.toString(),
        'package:my_app/main.dart',
      );
    });

    test('the pass runs with no package selected', () {
      // It rewrites what the build put in the snapshot, not the author's own
      // code, so there is nothing for `FS_PACKAGE` to say.
      final Component component = componentNamedBy(buildPath);
      libraryIn(component, 'dart:core');

      final logs = <String>[];
      final bool ran = Shield(
        filter: const PackageFilter.none(),
        passes: const <ObfuscationPass>[PathScrubPass()],
        logger: logs.add,
      ).harden(component);

      expect(ran, isTrue, reason: logs.join('\n'));
      expect(component.libraries.first.importUri.isScheme('file'), isTrue);
      expect(
        component.libraries.first.importUri.toString(),
        startsWith(PathScrubPass.scrubbedRoot),
      );
    });

    test('a scoped pass is still skipped with no package selected', () {
      final Component component = componentNamedBy(buildPath);
      libraryIn(component, 'dart:core');

      final logs = <String>[];
      final bool ran = Shield(
        filter: const PackageFilter.none(),
        passes: const <ObfuscationPass>[FieldShufflePass()],
        logger: logs.add,
      ).harden(component);

      expect(ran, isFalse, reason: logs.join('\n'));
    });
  });

  group('a compiled snapshot', () {
    late Directory fixture;
    late String appDill;

    setUpAll(() {
      fixture = Directory.systemTemp.createTempSync('flutter_shield_test');
      // Compiled from a loose file rather than from `lib/`, which is what
      // makes the front end name the library by its path, the way it names
      // the generated plugin registrant.
      File(p.join(fixture.path, 'dart_plugin_registrant.dart'))
          .writeAsStringSync(registrantFixture);
      appDill = p.join(fixture.path, 'app.dill');
      final ProcessResult compiled = Process.runSync(
        Platform.resolvedExecutable,
        <String>[
          'compile',
          'kernel',
          p.join(fixture.path, 'dart_plugin_registrant.dart'),
          '-o',
          appDill,
        ],
        workingDirectory: fixture.path,
      );
      expect(
        compiled.exitCode,
        0,
        reason: '${compiled.stdout}\n${compiled.stderr}',
      );
    });

    tearDownAll(() => fixture.deleteSync(recursive: true));

    test('keeps no trace of the build path and still runs', () async {
      final String path = fixture.path;
      final Component component = loadComponentFromBinary(appDill);
      expect(
        component.libraries.any(
          (Library library) => library.importUri.toString().contains(path),
        ),
        isTrue,
        reason: 'the fixture should start out named by its path',
      );

      final logs = <String>[];
      final bool ran = Shield(
        filter: const PackageFilter.none(),
        passes: const <ObfuscationPass>[PathScrubPass()],
        logger: logs.add,
      ).harden(component);
      expect(ran, isTrue, reason: logs.join('\n'));

      verifyComponent(
        NoneTarget(TargetFlags()),
        VerificationStage.afterModularTransformations,
        component,
        skipPlatform: true,
      );

      // The catch-all: whatever the pass missed would still be in the bytes,
      // including a canonical name or a metadata entry no assertion above
      // reaches.
      final String scrubbed = p.join(fixture.path, 'scrubbed.dill');
      await writeSnapshot(component, scrubbed);
      final String bytes = String.fromCharCodes(
        File(scrubbed).readAsBytesSync(),
      );
      expect(bytes.contains(path), isFalse, reason: 'the path is still there');
      expect(bytes.contains('flutter_shield'), isTrue);

      // And it still does what it did, which is what breaks if the library
      // and the name it is looked up by stop agreeing.
      final ProcessResult after = Process.runSync(
        Platform.resolvedExecutable,
        <String>[scrubbed],
      );
      expect(after.exitCode, 0, reason: '${after.stdout}\n${after.stderr}');
      expect(after.stdout, contains('registered'));
    });
  });
}
