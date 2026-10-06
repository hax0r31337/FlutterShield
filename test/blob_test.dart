import 'dart:math';

import 'package:flutter_shield/passes/string_encryption.dart';
import 'package:test/test.dart';

/// Checks that every value can be read back out of the blob at its offset.
void expectHolds(StringBlob blob, Iterable<String> values) {
  for (final String value in values) {
    final int offset = blob.offsetOf(value);
    expect(
      blob.text.substring(offset, offset + value.length),
      value,
      reason: 'blob does not hold "$value" at $offset',
    );
  }
}

StringBlob blobOf(Iterable<String> values, {int maxOverlap = 64}) =>
    (StringBlobBuilder(maxOverlap: maxOverlap)..addAll(values)).build();

void main() {
  test('an empty builder yields an empty blob', () {
    expect(blobOf(const <String>[]).text, isEmpty);
    expect(blobOf(const <String>['']).text, isEmpty);
  });

  test('holds a single value', () {
    final StringBlob blob = blobOf(const <String>['hello']);
    expect(blob.text, 'hello');
    expect(blob.offsetOf('hello'), 0);
  });

  test('stores duplicates once', () {
    final StringBlob blob = blobOf(const <String>['hello', 'hello']);
    expect(blob.text, 'hello');
    expect(blob.values, hasLength(1));
  });

  test('stores a value that occurs inside another for free', () {
    final StringBlob blob = blobOf(const <String>[
      'shielded world',
      'world',
      'ded wo',
    ]);
    expect(blob.text, 'shielded world');
    expect(blob.offsetOf('world'), 9);
    expect(blob.offsetOf('ded wo'), 5);
    expect(blob.savedCodeUnits, 'world'.length + 'ded wo'.length);
  });

  test('overlaps a suffix with a prefix', () {
    final StringBlob blob = blobOf(const <String>[
      'obfuscation',
      'cationary',
      'nary tale',
    ]);
    expectHolds(blob, const <String>['obfuscation', 'cationary', 'nary tale']);
    expect(blob.text, 'obfuscationary tale');
    expect(blob.savedCodeUnits, 10);
  });

  test('honours the overlap limit', () {
    final values = <String>['aaaaaaaa', 'aaaaaaab'];
    expect(blobOf(values, maxOverlap: 7).text.length, 9);
    expect(blobOf(values, maxOverlap: 1).text.length, 15);
    expectHolds(blobOf(values, maxOverlap: 1), values);
  });

  test('does not chain a value into itself', () {
    // Every value here both starts and ends with 'ab', so the greedy pass has
    // to keep the chains from closing into a cycle.
    final values = <String>['abcab', 'abdab', 'abeab'];
    final StringBlob blob = blobOf(values);
    expectHolds(blob, values);
  });

  test('packs random strings without losing any of them', () {
    final random = Random(20261006);
    const String alphabet = 'abcde';
    final values = <String>{};
    for (int i = 0; i < 400; i++) {
      final length = 1 + random.nextInt(12);
      values.add(
        String.fromCharCodes(
          List<int>.generate(
            length,
            (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length)),
          ),
        ),
      );
    }

    final StringBlob blob = blobOf(values);
    expectHolds(blob, values);
    expect(blob.values.toSet(), values);
    // Random strings over a small alphabet share a lot of text, so packing has
    // to beat plain concatenation by a wide margin.
    final int concatenated = values.fold<int>(
      0,
      (int sum, String v) => sum + v.length,
    );
    expect(blob.length, lessThan(concatenated * 2 ~/ 3));
  });
}
