@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:flutter_shield/flutter_shield.dart';
import 'package:kernel/kernel.dart';
import 'package:kernel/target/targets.dart';
import 'package:kernel/verifier.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String fixtureLibrary = r'''
const String kConstGreeting = 'a constant greeting';

class Greeter {
  Greeter(this.name);

  final String name;

  String greet() => 'hello, $name! welcome to the shielded world';

  String category(int value) {
    switch (value) {
      case 0:
        return 'the zero value';
      default:
        return 'some other value';
    }
  }

  @pragma('vm:prefer-inline')
  String annotated([String suffix = 'the default suffix']) => 'annotated with $suffix';
}

String joined() {
  const Map<String, int> table = <String, int>{'a constant key': 1};
  final List<String> parts = <String>['hello, ', 'shielded', ' world'];
  return '${parts.join()} / ${table.keys.first} / $kConstGreeting';
}
''';

const String fixtureMain = r'''
import 'package:fixture/fixture.dart';

void main() {
  print(Greeter('masaki').greet());
  print(Greeter('x').category(0));
  print(Greeter('x').category(7));
  print(Greeter('x').annotated());
  print(Greeter('x').annotated('a given suffix'));
  print(joined());
  print('a literal in the entrypoint');
}
''';

/// Every string an expression of [library] yields, in either of the two forms
/// a snapshot can hold them in.
List<String> stringsOf(Library library) {
  final collector = _StringCollector();
  library.accept(collector);
  return collector.values;
}

class _StringCollector extends RecursiveVisitor {
  final values = <String>[];

  @override
  void visitStringLiteral(StringLiteral node) => values.add(node.value);

  @override
  void visitConstantExpression(ConstantExpression node) {
    final Constant constant = node.constant;
    if (constant is StringConstant) {
      values.add(constant.value);
    }
  }
}

void main() {
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

  test('the hardened snapshot behaves like the original', () async {
    final ProcessResult before = Process.runSync(
      Platform.resolvedExecutable,
      <String>[appDill],
    );
    expect(before.exitCode, 0, reason: '${before.stderr}');

    // The platform has to be part of the component for the generated code to
    // reference dart:core, the way it is in a release snapshot.
    final Component component = loadComponentFromBinary(platformDill);
    loadComponentFromBinary(appDill, component);

    final logs = <String>[];
    final bool ran = Shield(
      filter: PackageFilter.parse(r'^fixture$'),
      passes: const <ObfuscationPass>[StringEncryptionPass(seed: 0x5EED)],
      logger: logs.add,
    ).harden(component);
    expect(ran, isTrue, reason: logs.join('\n'));
    expect(logs.join('\n'), contains('string-encryption:'));

    verifyComponent(
      NoneTarget(TargetFlags()),
      VerificationStage.afterModularTransformations,
      component,
      skipPlatform: true,
    );

    final Library fixtureLibrary = component.libraries.firstWhere(
      (Library library) =>
          library.importUri.toString() == 'package:fixture/fixture.dart',
    );
    final Library entrypoint = component.libraries.firstWhere(
      (Library library) => library.importUri.path.endsWith('bin/main.dart'),
    );

    // Everything the selected library used to say is gone, except what has to
    // stay constant: the default parameter value and the const field. The
    // annotation and the key of the const map are strings inside a larger
    // constant, which is not an expression at all, so they are not listed
    // here - and are left alone for the same reason.
    expect(stringsOf(fixtureLibrary), <String>[
      'the default suffix',
      'a constant greeting',
    ]);
    // The entrypoint is not a package library, so it is left alone.
    expect(stringsOf(entrypoint), contains('a literal in the entrypoint'));

    final String hardenedDill = p.join(fixture.path, 'hardened.dill');
    await writeSnapshot(component, hardenedDill);

    final ProcessResult after = Process.runSync(
      Platform.resolvedExecutable,
      <String>[hardenedDill],
    );
    expect(after.exitCode, 0, reason: '${after.stderr}');
    expect(after.stdout, before.stdout);
    expect(
      after.stdout,
      contains('hello, masaki! welcome to the shielded world'),
    );

    // And the strings are no longer anywhere in the snapshot. The sources the
    // snapshot embeds are the compiler's copy of the fixture, so they are
    // excluded from the check.
    final Component reread = readSnapshot(hardenedDill);
    reread.uriToSource.clear();
    final String hardenedSansSources = p.join(fixture.path, 'stripped.dill');
    await writeComponentToBinary(reread, hardenedSansSources);
    final List<int> bytes = File(hardenedSansSources).readAsBytesSync();
    expect(
      String.fromCharCodes(bytes),
      isNot(contains('welcome to the shielded world')),
    );
  });

  test('nothing is touched when no package is selected', () async {
    final Component component = loadComponentFromBinary(platformDill);
    loadComponentFromBinary(appDill, component);

    final logs = <String>[];
    expect(
      Shield(
        filter: PackageFilter.parse(null),
        logger: logs.add,
      ).harden(component),
      isFalse,
    );
    expect(logs.join('\n'), contains('no package filter'));

    expect(
      Shield(
        filter: PackageFilter.parse(r'^nothing_matches$'),
        logger: logs.add,
      ).harden(component),
      isFalse,
    );
    expect(
      component.libraries.map(
        (Library library) => library.importUri.toString(),
      ),
      isNot(contains(startsWith('package:flutter_shield/'))),
    );
  });
}
