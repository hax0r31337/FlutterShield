import 'package:kernel/ast.dart';

import '../../ast_builder.dart';
import '../../pass.dart';
import 'cipher.dart';

/// The code [StringEncryptionPass] generates into the snapshot: the encrypted
/// blob, one decrypt function shared by every string, and one static cache
/// variable per string.
///
/// The generated decrypt function is, in Dart source:
///
/// ```dart
/// String _d(int off, int len, int key) {
///   final List<int> out = List<int>.filled(len, 0);
///   for (int i = 0; i < len; i++) {
///     final int c = _blob[off + i] ^ (((key >> 11) ^ (key >> 3)) & 0xFFFF);
///     out[i] = c;
///     key = (key * 0x41C64E6D + c * 0x9E3779B1 + 0x3039) & 0xFFFFFFFF;
///   }
///   return String.fromCharCodes(out);
/// }
/// ```
///
/// where `_blob` is a constant list of code units inlined into the body, and
/// the arithmetic is [RollingKeyCipher] read backwards. Every call site is
///
/// ```dart
/// _s17 ??= _d(offset, length, keyState)
/// ```
///
/// so a string is decrypted at most once per process and never appears in the
/// snapshot's string table.
class StringRuntime {
  StringRuntime(PassContext context, EncryptedBlob blob)
    : _context = context,
      library = context.addSupportLibrary('strings') {
    _decrypt = _buildDecrypt(blob);
    applyFileOffset(_decrypt, 0);
    library.addProcedure(_decrypt);
  }

  final PassContext _context;

  /// The library holding the generated code.
  final Library library;

  late final Procedure _decrypt;

  final Map<String, Field> _caches = <String, Field>{};

  AstBuilder get _ast => _context.ast;

  /// How many static cache variables were generated.
  int get cacheCount => _caches.length;

  /// An expression that yields [value] at runtime, reading it out of the blob
  /// at [offset] with [key] as the initial key state.
  Expression read(String value, {required int offset, required int key}) {
    final Field cache = _caches.putIfAbsent(value, () {
      final field = Field.mutable(
        Name('_s${_caches.length}', library),
        type: _ast.nullableStringType,
        isStatic: true,
        fileUri: library.fileUri,
      );
      applyFileOffset(field, 0);
      library.addField(field);
      return field;
    });

    return _ast.cacheString(
      cache,
      StaticInvocation(
        _decrypt,
        Arguments(<Expression>[
          IntLiteral(offset),
          IntLiteral(value.length),
          IntLiteral(key),
        ]),
      ),
    );
  }

  Procedure _buildDecrypt(EncryptedBlob blob) {
    final offset = PositionalParameter(cosmeticName: 'off', type: _ast.intType);
    final length = PositionalParameter(cosmeticName: 'len', type: _ast.intType);
    final key = PositionalParameter(cosmeticName: 'key', type: _ast.intType);

    final out = LocalVariable(
      name: 'out',
      type: _ast.intListType,
      isFinal: true,
      initializer: _ast.filledIntList(VariableGet(length)),
    );
    final index = LocalVariable(
      name: 'i',
      type: _ast.intType,
      initializer: IntLiteral(0),
    );

    // _blob[off + i] ^ (((key >> 11) ^ (key >> 3)) & 0xFFFF)
    final plain = LocalVariable(
      name: 'c',
      type: _ast.intType,
      isFinal: true,
      initializer: _ast.bitXor(
        _ast.intListGet(
          _ast.constIntList(blob.codeUnits),
          _ast.add(VariableGet(offset), VariableGet(index)),
        ),
        _ast.bitAnd(
          _ast.bitXor(
            _ast.shiftRight(VariableGet(key), 11),
            _ast.shiftRight(VariableGet(key), 3),
          ),
          IntLiteral(0xFFFF),
        ),
      ),
    );

    // key = (key * keyFactor + c * plainFactor + increment) & mask32
    final Expression nextKey = _ast.bitAnd(
      _ast.add(
        _ast.add(
          _ast.multiply(
            VariableGet(key),
            IntLiteral(RollingKeyCipher.keyFactor),
          ),
          _ast.multiply(
            VariableGet(plain),
            IntLiteral(RollingKeyCipher.plainFactor),
          ),
        ),
        IntLiteral(RollingKeyCipher.increment),
      ),
      IntLiteral(RollingKeyCipher.mask32),
    );

    final body = Block(<Statement>[
      VariableStatement(VariableDeclaration(out)),
      ForStatement(
        <VariableDeclaration>[VariableDeclaration(index)],
        _ast.lessThan(VariableGet(index), VariableGet(length)),
        <Expression>[
          VariableSet(index, _ast.add(VariableGet(index), IntLiteral(1))),
        ],
        Block(<Statement>[
          VariableStatement(VariableDeclaration(plain)),
          ExpressionStatement(
            _ast.intListSet(
              VariableGet(out),
              VariableGet(index),
              VariableGet(plain),
            ),
          ),
          ExpressionStatement(VariableSet(key, nextKey)),
        ]),
      ),
      ReturnStatement(_ast.stringFromCharCodes(VariableGet(out))),
    ]);

    return Procedure(
      Name('_d', library),
      ProcedureKind.Method,
      FunctionNode(
        body,
        positionalParameters: <PositionalParameter>[offset, length, key],
        returnType: _ast.stringType,
      ),
      isStatic: true,
      fileUri: library.fileUri,
    );
  }
}
