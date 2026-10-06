import 'dart:math';

import 'package:flutter_shield/passes/string_encryption.dart';
import 'package:test/test.dart';

/// The decrypt loop the pass generates into the snapshot, in Dart.
///
/// If this and `StringRuntime` ever disagree, the generated code decrypts to
/// garbage, so it is spelled out here rather than reusing the cipher's own
/// helpers.
String decrypt(List<int> blob, int offset, int length, int key) {
  final out = List<int>.filled(length, 0);
  for (int i = 0; i < length; i++) {
    final int c = blob[offset + i] ^ (((key >> 11) ^ (key >> 3)) & 0xFFFF);
    out[i] = c;
    key = (key * 0x41C64E6D + c * 0x9E3779B1 + 0x3039) & 0xFFFFFFFF;
  }
  return String.fromCharCodes(out);
}

void main() {
  test('recovers the whole blob', () {
    const text = 'the quick brown fox jumps over the lazy dog';
    final EncryptedBlob blob = const RollingKeyCipher(0x1234).encrypt(text);
    expect(blob.codeUnits, hasLength(text.length));
    expect(decrypt(blob.codeUnits, 0, text.length, blob.keyAt(0)), text);
  });

  test('recovers a slice from the key state of its offset', () {
    const text = 'hello, shielded world';
    final EncryptedBlob blob = const RollingKeyCipher(0xC0FFEE).encrypt(text);
    for (int offset = 0; offset < text.length; offset++) {
      final int length = text.length - offset;
      expect(
        decrypt(blob.codeUnits, offset, length, blob.keyAt(offset)),
        text.substring(offset),
        reason: 'failed at offset $offset',
      );
    }
  });

  test('keeps the keystream inside 16 bits and the key inside 32', () {
    int key = 0xFFFFFFFF;
    for (int i = 0; i < 1000; i++) {
      expect(RollingKeyCipher.keystream(key), inInclusiveRange(0, 0xFFFF));
      key = RollingKeyCipher.step(key, 0xFFFF);
      expect(key, inInclusiveRange(0, 0xFFFFFFFF));
    }
  });

  test('the next key depends on what was just decrypted', () {
    const int key = 0x5EED;
    expect(RollingKeyCipher.step(key, 1), isNot(RollingKeyCipher.step(key, 2)));
  });

  test('a different seed gives a different ciphertext', () {
    const text = 'the same plaintext twice';
    expect(
      const RollingKeyCipher(1).encrypt(text).codeUnits,
      isNot(const RollingKeyCipher(2).encrypt(text).codeUnits),
    );
  });

  test('handles code units outside the basic latin range', () {
    const text = 'naïve — 日本語 🎲 ok';
    final EncryptedBlob blob = const RollingKeyCipher(7).encrypt(text);
    expect(decrypt(blob.codeUnits, 0, text.length, blob.keyAt(0)), text);
    for (final int unit in blob.codeUnits) {
      expect(unit, inInclusiveRange(0, 0xFFFF));
    }
  });

  test('recovers random text from random offsets', () {
    final random = Random(20261006);
    final text = String.fromCharCodes(
      List<int>.generate(2000, (_) => 1 + random.nextInt(0xFFFE)),
    );
    final EncryptedBlob blob = RollingKeyCipher(random.nextInt(0xFFFFFFFF))
        .encrypt(text);
    for (int i = 0; i < 100; i++) {
      final int offset = random.nextInt(text.length);
      final int length = random.nextInt(text.length - offset);
      expect(
        decrypt(blob.codeUnits, offset, length, blob.keyAt(offset)),
        text.substring(offset, offset + length),
      );
    }
  });
}
