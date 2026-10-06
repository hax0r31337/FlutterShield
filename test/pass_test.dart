import 'dart:typed_data';

import 'package:flutter_shield/flutter_shield.dart';
import 'package:kernel/ast.dart';
import 'package:test/test.dart';

/// The URI roots `gen_snapshot` knows how to turn back into a source path,
/// from `runtime/vm/debug_info.cc` of the Dart SDK.
///
/// A build with `--split-debug-info` resolves the file URI of every library
/// the AOT compiler emits code for, and aborts on one whose root is none of
/// these - `cannot convert resolved URI ...`.
const List<String> resolvableRoots = <String>[
  'file:///',
  'org-dartlang-sdk:///',
  'google3:///',
];

PassContext contextOf(Component component) => PassContext(
  component: component,
  filter: PackageFilter.parse(r'^my_app$'),
  logger: (String message) {},
);

Library libraryAt(Uri importUri, Uri fileUri, Component component) {
  final library = Library(importUri, fileUri: fileUri);
  component.libraries.add(library);
  library.parent = component;
  component.uriToSource[fileUri] = Source(
    <int>[0],
    Uint8List(0),
    importUri,
    fileUri,
  );
  return library;
}

void main() {
  test('a support library gets a file URI gen_snapshot can resolve', () {
    final component = Component();
    final Library support = contextOf(component).addSupportLibrary('strings');

    expect(
      resolvableRoots.any(support.fileUri.toString().startsWith),
      isTrue,
      reason: 'gen_snapshot cannot resolve ${support.fileUri}',
    );
    // The path is looked up in the source entry keyed by the file URI, so
    // that is the URI that has to resolve, not the import URI.
    expect(component.uriToSource.keys, contains(support.fileUri));
    expect(
      component.uriToSource[support.fileUri]!.importUri,
      support.importUri,
    );
  });

  test('support libraries do not share their URIs', () {
    final component = Component();
    final PassContext context = contextOf(component);
    final Library first = context.addSupportLibrary('strings');
    final Library second = context.addSupportLibrary('strings');

    expect(second.importUri, isNot(first.importUri));
    expect(second.fileUri, isNot(first.fileUri));
    expect(
      component.uriToSource.keys,
      containsAll(<Uri>[first.fileUri, second.fileUri]),
    );
  });

  test('a support library leaves a source of the app alone', () {
    // Whichever URIs a support library would claim, a library of the
    // application that already holds one of them keeps it, source and all.
    final Uri contested = contextOf(Component())
        .addSupportLibrary('strings')
        .fileUri;

    final component = Component();
    final Library app = libraryAt(
      Uri.parse('package:my_app/main.dart'),
      contested,
      component,
    );

    final Library support = contextOf(component).addSupportLibrary('strings');
    expect(support.fileUri, isNot(contested));
    expect(component.uriToSource[contested]!.importUri, app.importUri);
  });

  group('pass selection', () {
    const List<ObfuscationPass> available = <ObfuscationPass>[
      FieldShufflePass(),
      StringEncryptionPass(),
    ];

    List<String> namesOf(String? value) => selectPasses(
      available,
      value,
    ).map((ObfuscationPass pass) => pass.name).toList();

    test('an unset or blank value selects every pass', () {
      expect(namesOf(null), <String>['field-shuffle', 'string-encryption']);
      expect(namesOf(''), <String>['field-shuffle', 'string-encryption']);
      expect(namesOf('  '), <String>['field-shuffle', 'string-encryption']);
    });

    test('a value selects the passes it names', () {
      expect(namesOf('string-encryption'), <String>['string-encryption']);
      expect(namesOf('field-shuffle'), <String>['field-shuffle']);
    });

    test('the selected passes keep the order they have to run in', () {
      // Whichever order the value lists them in, and however often.
      expect(namesOf('string-encryption,field-shuffle'), <String>[
        'field-shuffle',
        'string-encryption',
      ]);
      expect(
        namesOf(' string-encryption , field-shuffle , field-shuffle '),
        <String>['field-shuffle', 'string-encryption'],
      );
    });

    test('a value naming an unknown pass is rejected', () {
      // Running fewer passes than the build asked for has to fail loudly,
      // rather than ship a snapshot the author believes is hardened.
      expect(
        () => selectPasses(available, 'string-encrytpion'),
        throwsA(
          isA<FormatException>().having(
            (FormatException error) => error.message,
            'message',
            allOf(
              contains('string-encrytpion'),
              contains('field-shuffle, string-encryption'),
            ),
          ),
        ),
      );
      expect(
        () => selectPasses(available, 'field-shuffle,nope'),
        throwsFormatException,
      );
    });

    test('a value naming no pass at all is rejected', () {
      expect(() => selectPasses(available, ','), throwsFormatException);
    });
  });
}
