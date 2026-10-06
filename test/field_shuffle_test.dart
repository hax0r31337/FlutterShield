@Timeout(Duration(minutes: 5))
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_shield/flutter_shield.dart';
import 'package:kernel/kernel.dart';
import 'package:kernel/target/targets.dart';
import 'package:kernel/verifier.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String fixtureLibrary = r'''
int _ticks = 0;

/// Something an initializer can do that another initializer can tell apart.
int tick() => ++_ticks;

/// Every field declares an initializer nothing can observe, so the whole class
/// is free to be reordered.
class Inert {
  int alpha = 1;
  String bravo = 'two';
  double charlie = 3.5;
  bool delta = true;
  List<int> echo = <int>[];
  Map<String, int> foxtrot = <String, int>{'g': 7};
  int? golf;
  Type hotel = Inert;
  static int india = tick();

  @override
  String toString() =>
      'Inert($alpha, $bravo, $charlie, $delta, $echo, $foxtrot, $golf, $hotel)';
}

/// The initializers of [first], [second] and [third] run in declaration order,
/// and say so.
class Ordered {
  int first = tick();
  String padding = 'between the ticks';
  int second = tick();
  List<String> more = <String>['and', 'more'];
  int third = tick();
  late int lazy = tick();

  @override
  String toString() => 'Ordered($first, $second, $third)';
}

/// Nothing to evaluate at all: a constructor fills these in.
class Constructed {
  Constructed(this.x, this.y, this.z);

  final int x;
  final int y;
  final int z;

  @override
  String toString() => 'Constructed($x, $y, $z)';
}

enum Flavour {
  sweet(1, 'sugar'),
  sour(2, 'lemon');

  const Flavour(this.weight, this.source);

  final int weight;
  final String source;

  @override
  String toString() => 'Flavour($name, $weight, $source)';
}
''';

const String fixtureMain = r'''
import 'package:fixture/fixture.dart';

void main() {
  print(Ordered());
  print(Ordered());
  print(Inert());
  print(Constructed(1, 2, 3));
  print(Inert.india);
  print(Flavour.values.join(' '));
}
''';

/// The fields of [name] in the order [library] declares them.
List<String> fieldsOf(Library library, String name) => library.classes
    .firstWhere((Class node) => node.name == name)
    .fields
    .map((Field field) => field.name.text)
    .toList(growable: false);

PassContext contextOf(Component component) => PassContext(
  component: component,
  filter: PackageFilter.parse(r'^my_app$'),
  logger: (String message) {},
);

Library libraryIn(Component component, String importUri) {
  final Uri uri = Uri.parse(importUri);
  final library = Library(uri, fileUri: uri);
  component.libraries.add(library);
  library.parent = component;
  component.uriToSource[uri] = Source(<int>[0], Uint8List(0), uri, uri);
  return library;
}

Class classIn(
  Library library,
  String name,
  List<Field> fields, {
  Supertype? supertype,
}) {
  final node = Class(
    name: name,
    fileUri: library.fileUri,
    supertype: supertype,
    fields: fields,
  );
  library.addClass(node);
  return node;
}

Field fieldIn(Library library, String name, {Expression? initializer}) =>
    Field.mutable(
      Name(name, library),
      fileUri: library.fileUri,
      initializer: initializer,
    );

void main() {
  group('synthetic components', () {
    test('a dart:ffi compound keeps its declaration order', () {
      final component = Component();
      final Library ffi = libraryIn(component, 'dart:ffi');
      final Class struct = classIn(ffi, 'Struct', <Field>[]);

      final Library app = libraryIn(component, 'package:my_app/main.dart');
      const List<String> names = <String>['a', 'b', 'c', 'd', 'e', 'f'];
      classIn(app, 'Point', <Field>[
        for (final String name in names) fieldIn(app, name),
      ], supertype: Supertype(struct, const <DartType>[]));
      classIn(app, 'NotAPoint', <Field>[
        for (final String name in names) fieldIn(app, name),
      ]);

      const FieldShufflePass(seed: 0x5EED).run(contextOf(component));

      expect(fieldsOf(app, 'Point'), names);
      expect(fieldsOf(app, 'NotAPoint'), isNot(names));
      expect(fieldsOf(app, 'NotAPoint')..sort(), names);
    });

    test('libraries the filter does not select are left alone', () {
      final component = Component();
      final Library other = libraryIn(component, 'package:other/other.dart');
      const List<String> names = <String>['a', 'b', 'c', 'd', 'e', 'f'];
      classIn(other, 'Thing', <Field>[
        for (final String name in names) fieldIn(other, name),
      ]);

      const FieldShufflePass(seed: 0x5EED).run(contextOf(component));

      expect(fieldsOf(other, 'Thing'), names);
    });

    test('a fixed seed reorders the same way twice', () {
      List<String> order() {
        final component = Component();
        final Library app = libraryIn(component, 'package:my_app/main.dart');
        classIn(app, 'Thing', <Field>[
          for (final String name in <String>['a', 'b', 'c', 'd', 'e', 'f'])
            fieldIn(app, name),
        ]);
        const FieldShufflePass(seed: 0x5EED).run(contextOf(component));
        return fieldsOf(app, 'Thing');
      }

      expect(order(), order());
    });
  });

  group('a compiled fixture', () {
    final String sdk = p.dirname(p.dirname(Platform.resolvedExecutable));
    final String platformDill = p.join(
      sdk,
      'lib',
      '_internal',
      'vm_platform.dill',
    );

    late Directory fixture;
    late String appDill;

    setUpAll(() {
      fixture = Directory.systemTemp.createTempSync('flutter_shield_test');
      Directory(p.join(fixture.path, 'lib')).createSync();
      Directory(p.join(fixture.path, 'bin')).createSync();
      Directory(p.join(fixture.path, '.dart_tool')).createSync();
      File(p.join(fixture.path, 'pubspec.yaml'))
          .writeAsStringSync('name: fixture\nenvironment:\n  sdk: ^3.13.0\n');
      File(p.join(fixture.path, '.dart_tool', 'package_config.json'))
          .writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    {"name": "fixture", "rootUri": "../", "packageUri": "lib/", "languageVersion": "3.13"}
  ]
}
''');
      File(p.join(fixture.path, 'lib', 'fixture.dart'))
          .writeAsStringSync(fixtureLibrary);
      File(p.join(fixture.path, 'bin', 'main.dart'))
          .writeAsStringSync(fixtureMain);

      appDill = p.join(fixture.path, 'app.dill');
      final ProcessResult compiled = Process.runSync(
        Platform.resolvedExecutable,
        <String>[
          'compile',
          'kernel',
          p.join(fixture.path, 'bin', 'main.dart'),
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

    test('is reordered without changing what it does', () async {
      final ProcessResult before = Process.runSync(
        Platform.resolvedExecutable,
        <String>[appDill],
      );
      expect(before.exitCode, 0, reason: '${before.stderr}');

      final Component component = loadComponentFromBinary(platformDill);
      loadComponentFromBinary(appDill, component);

      final Library library = component.libraries.firstWhere(
        (Library library) =>
            library.importUri.toString() == 'package:fixture/fixture.dart',
      );
      final List<String> inertBefore = fieldsOf(library, 'Inert');
      final List<String> orderedBefore = fieldsOf(library, 'Ordered');

      final logs = <String>[];
      final bool ran = Shield(
        filter: PackageFilter.parse(r'^fixture$'),
        passes: const <ObfuscationPass>[FieldShufflePass(seed: 0x5EED)],
        logger: logs.add,
      ).harden(component);
      expect(ran, isTrue, reason: logs.join('\n'));
      expect(logs.join('\n'), contains('field-shuffle:'));

      verifyComponent(
        NoneTarget(TargetFlags()),
        VerificationStage.afterModularTransformations,
        component,
        skipPlatform: true,
      );

      // Nothing an initializer of `Inert` does can be observed, so every one
      // of its fields was free to move.
      final List<String> inertAfter = fieldsOf(library, 'Inert');
      expect(inertAfter, isNot(inertBefore));
      expect(inertAfter.toSet(), inertBefore.toSet());

      // `Ordered` moved too, but the three fields whose initializers call
      // `tick()` still run in the order they used to.
      final List<String> orderedAfter = fieldsOf(library, 'Ordered');
      expect(orderedAfter, isNot(orderedBefore));
      expect(orderedAfter.toSet(), orderedBefore.toSet());
      bool ticking(String name) =>
          const <String>{'first', 'second', 'third'}.contains(name);
      expect(
        orderedAfter.where(ticking),
        orderedBefore.where(ticking),
        reason: 'the observable initializers were reordered',
      );

      final String hardenedDill = p.join(fixture.path, 'hardened.dill');
      await writeSnapshot(component, hardenedDill);

      final ProcessResult after = Process.runSync(
        Platform.resolvedExecutable,
        <String>[hardenedDill],
      );
      expect(after.exitCode, 0, reason: '${after.stderr}');
      expect(after.stdout, before.stdout);
      expect(after.stdout, contains('Ordered(1, 2, 3)'));
    });

    test('survives the whole default pipeline', () async {
      // Field shuffling reads the field initializers and string encryption
      // rewrites them, so the two passes have to be run in the order
      // [Shield.defaultPasses] lists them, and the result still has to behave.
      final ProcessResult before = Process.runSync(
        Platform.resolvedExecutable,
        <String>[appDill],
      );
      expect(before.exitCode, 0, reason: '${before.stderr}');

      final Component component = loadComponentFromBinary(platformDill);
      loadComponentFromBinary(appDill, component);

      final logs = <String>[];
      expect(
        Shield(
          filter: PackageFilter.parse(r'^fixture$'),
          random: Random(0x5EED),
          logger: logs.add,
        ).harden(component),
        isTrue,
        reason: logs.join('\n'),
      );
      expect(logs.join('\n'), contains('field-shuffle:'));
      expect(logs.join('\n'), contains('string-encryption:'));

      verifyComponent(
        NoneTarget(TargetFlags()),
        VerificationStage.afterModularTransformations,
        component,
        skipPlatform: true,
      );

      final String hardenedDill = p.join(fixture.path, 'pipeline.dill');
      await writeSnapshot(component, hardenedDill);

      final ProcessResult after = Process.runSync(
        Platform.resolvedExecutable,
        <String>[hardenedDill],
      );
      expect(after.exitCode, 0, reason: '${after.stderr}');
      expect(after.stdout, before.stdout);
    });
  });
}
