import 'package:flutter_shield/package_filter.dart';
import 'package:kernel/ast.dart';
import 'package:test/test.dart';

Library libraryAt(String uri) {
  final parsed = Uri.parse(uri);
  return Library(parsed, fileUri: parsed);
}

void main() {
  test('an unset pattern selects nothing', () {
    for (final PackageFilter filter in <PackageFilter>[
      PackageFilter.parse(null),
      PackageFilter.parse(''),
      const PackageFilter.none(),
    ]) {
      expect(filter.selectsNothing, isTrue);
      expect(filter.allows(libraryAt('package:my_app/main.dart')), isFalse);
    }
  });

  test('selects the packages the pattern matches', () {
    final filter = PackageFilter.parse(r'^my_app$');
    expect(filter.selectsNothing, isFalse);
    expect(filter.allows(libraryAt('package:my_app/main.dart')), isTrue);
    expect(
      filter.allows(libraryAt('package:my_app/src/deep/file.dart')),
      isTrue,
    );
    expect(
      filter.allows(libraryAt('package:my_app_models/model.dart')),
      isFalse,
    );
    expect(filter.allows(libraryAt('package:flutter/material.dart')), isFalse);
  });

  test('the pattern is not anchored for you', () {
    final filter = PackageFilter.parse('my_app');
    expect(
      filter.allows(libraryAt('package:my_app_models/model.dart')),
      isTrue,
    );
    expect(filter.allows(libraryAt('package:not_my_app/model.dart')), isTrue);
  });

  test('matches several packages', () {
    final filter = PackageFilter.parse(r'^(my_app|my_models)$');
    expect(filter.allows(libraryAt('package:my_app/main.dart')), isTrue);
    expect(filter.allows(libraryAt('package:my_models/model.dart')), isTrue);
    expect(filter.allows(libraryAt('package:other/other.dart')), isFalse);
  });

  test('never selects anything that is not a package library', () {
    final filter = PackageFilter.parse('.*');
    expect(filter.allows(libraryAt('dart:core')), isFalse);
    expect(filter.allows(libraryAt('dart:ui')), isFalse);
    expect(filter.allows(libraryAt('file:///app/lib/main.dart')), isFalse);
    expect(filter.allows(libraryAt('package:anything/main.dart')), isTrue);
  });

  test('reports an invalid pattern', () {
    expect(() => PackageFilter.parse('^my_app('), throwsFormatException);
  });

  test('reads the package name out of an import URI', () {
    expect(
      PackageFilter.packageOf(Uri.parse('package:my_app/a/b.dart')),
      'my_app',
    );
    expect(PackageFilter.packageOf(Uri.parse('dart:core')), isNull);
    expect(PackageFilter.packageOf(Uri.parse('file:///a/b.dart')), isNull);
  });
}
