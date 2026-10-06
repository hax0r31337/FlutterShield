/// The cipher shared by the [StringEncryptionPass] and the code it generates.
///
/// Every UTF-16 code unit of the blob is masked with a keystream drawn from a
/// 32 bit rolling key, and the key is then stirred with the code unit that was
/// just recovered - the next key depends on the previous decrypt result, so the
/// keystream cannot be replayed without decrypting what came before it.
///
/// The key rolls over the blob as a whole rather than per string, which is what
/// lets strings share bytes: the key state at a given offset is the same no
/// matter which string is being read through it. The generated decrypt function
/// therefore takes the key state of its offset as an argument, which is the one
/// thing an attacker gets for free; recovering a single string is cheap, but
/// the blob is only readable as a whole through the call sites that index it.
///
/// Only the masking is reversed at runtime, so the generated code is the
/// decrypt half of [encrypt]: both halves must stay in step, see
/// `runtime.dart`.
class RollingKeyCipher {
  const RollingKeyCipher(this.seed);

  /// Key state the blob starts from.
  final int seed;

  static const int mask32 = 0xFFFFFFFF;
  static const int keyFactor = 0x41C64E6D;
  static const int plainFactor = 0x9E3779B1;
  static const int increment = 0x3039;

  /// The key state that follows [key] after recovering [plain].
  static int step(int key, int plain) =>
      (key * keyFactor + plain * plainFactor + increment) & mask32;

  /// The 16 bit mask [key] contributes.
  static int keystream(int key) => ((key >> 11) ^ (key >> 3)) & 0xFFFF;

  /// Encrypts the code units of [text].
  EncryptedBlob encrypt(String text) {
    final List<int> plain = text.codeUnits;
    final codeUnits = List<int>.filled(plain.length, 0);
    final keyStates = List<int>.filled(plain.length, 0);

    int key = seed & mask32;
    for (int i = 0; i < plain.length; i++) {
      keyStates[i] = key;
      codeUnits[i] = plain[i] ^ keystream(key);
      key = step(key, plain[i]);
    }

    return EncryptedBlob(
      codeUnits: codeUnits,
      keyStates: keyStates,
      seed: seed,
    );
  }
}

/// An encrypted blob, and the key state at every offset in it.
class EncryptedBlob {
  const EncryptedBlob({
    required this.codeUnits,
    required this.keyStates,
    required this.seed,
  });

  /// The encrypted code units, as they are embedded in the snapshot.
  final List<int> codeUnits;

  /// The key state at each offset, of which only the offsets that start a
  /// string end up in the snapshot.
  final List<int> keyStates;

  final int seed;

  int get length => codeUnits.length;

  /// The key a reader has to start from to decrypt at [offset].
  int keyAt(int offset) => keyStates[offset];
}
