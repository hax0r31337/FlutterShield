import 'package:kernel/ast.dart';

import '../ast_builder.dart';
import '../pass.dart';
import '../snapshot.dart';
import 'string_encryption/blob.dart';
import 'string_encryption/cipher.dart';
import 'string_encryption/runtime.dart';

export 'string_encryption/blob.dart' show StringBlob, StringBlobBuilder;
export 'string_encryption/cipher.dart' show EncryptedBlob, RollingKeyCipher;

/// Replaces the string literals of the selected libraries with lazy reads out
/// of a single encrypted blob.
///
/// Every literal becomes `_sN ??= _d(offset, length, key)`: a static variable
/// per string, filled on first use by the one decrypt function the snapshot
/// holds. The strings themselves are packed into one blob - deduplicated, and
/// overlapped where one string occurs inside another - and that blob is
/// encrypted with a [RollingKeyCipher], so neither the string table of the
/// snapshot nor a dump of the blob gives the strings up.
///
/// Constants are left alone. A `const` expression has to stay constant for the
/// snapshot to be valid at all, which rules out `case 'x':`, annotations,
/// default parameter values, const collections and const constructor
/// arguments. In a release build the front end has already folded those into
/// kernel constants, which is what [_StringSites] recognises them by.
class StringEncryptionPass extends ObfuscationPass {
  const StringEncryptionPass({
    this.minLength = 2,
    this.maxOverlap = 64,
    this.seed,
  }) : assert(minLength >= 1);

  /// Strings shorter than this are left alone: a one character string costs
  /// more in call site and cache variable than it gives away.
  final int minLength;

  /// The longest overlap considered when packing the blob, see
  /// [StringBlobBuilder.maxOverlap].
  final int maxOverlap;

  /// Fixed cipher seed, for a reproducible build. A random seed is drawn per
  /// run when this is null.
  final int? seed;

  @override
  String get name => 'string-encryption';

  @override
  void run(PassContext context) {
    final sites = _StringSites(minLength: minLength);
    for (final Library library in context.libraries) {
      sites.collect(library);
    }
    if (sites.values.isEmpty) {
      context.log('string-encryption: no strings to encrypt');
      return;
    }

    final StringBlob blob = (StringBlobBuilder(
      maxOverlap: maxOverlap,
    )..addAll(sites.values)).build();
    final cipher = RollingKeyCipher(
      seed ?? context.random.nextInt(RollingKeyCipher.mask32),
    );
    final EncryptedBlob encrypted = cipher.encrypt(blob.text);
    final runtime = StringRuntime(context, encrypted);

    int rewritten = 0;
    for (final Library library in context.libraries) {
      sites.rewrite(library, (String value) {
        rewritten++;
        final int offset = blob.offsetOf(value);
        return runtime.read(
          value,
          offset: offset,
          key: encrypted.keyAt(offset),
        );
      });
    }

    dropRecordedStringConstants(context.component, sites.values);

    context.log(
      'string-encryption: $rewritten literals, ${runtime.cacheCount} distinct strings, '
      '${blob.length} code unit blob (${blob.savedCodeUnits} saved by overlapping)',
    );
  }
}

/// Visits every string literal of a library that can be replaced by a runtime
/// expression, either collecting the values or rewriting the literals.
///
/// Both halves have to agree on which literals they consider, so they are the
/// same traversal: [collect] records values, [rewrite] replaces them.
///
/// The traversal walks members itself instead of visiting a library wholesale,
/// to stay out of the places a kernel expression has to be constant:
/// annotations, parameter default values, `const` fields, initializers of
/// `const` constructors, switch case expressions and patterns.
class _StringSites extends Transformer {
  _StringSites({required this.minLength});

  final int minLength;

  /// The distinct values found by [collect].
  final Set<String> values = <String>{};

  /// Set while rewriting, null while collecting.
  Expression Function(String value)? _replace;

  void collect(Library library) {
    _replace = null;
    _visitLibrary(library);
  }

  void rewrite(Library library, Expression Function(String value) replace) {
    _replace = replace;
    _visitLibrary(library);
  }

  void _visitLibrary(Library library) {
    for (final Field field in library.fields) {
      _visitField(field);
    }
    for (final Procedure procedure in library.procedures) {
      _visitFunction(procedure.function);
    }
    for (final Class declaration in library.classes) {
      for (final Field field in declaration.fields) {
        _visitField(field);
      }
      for (final Procedure procedure in declaration.procedures) {
        _visitFunction(procedure.function);
      }
      for (final Constructor constructor in declaration.constructors) {
        if (constructor.isConst) {
          continue;
        }
        transformList(constructor.initializers, constructor);
        _visitFunction(constructor.function);
      }
    }
  }

  void _visitField(Field field) {
    final Expression? initializer = field.initializer;
    if (field.isConst || initializer == null) {
      return;
    }
    field.initializer = transform(initializer)..parent = field;
  }

  void _visitFunction(FunctionNode function) {
    final Statement? body = function.body;
    if (body == null) {
      return;
    }
    function.body = transform(body)..parent = function;
  }

  @override
  TreeNode visitStringLiteral(StringLiteral node) =>
      _visitString(node, node.value);

  /// A string the front end already folded into a constant.
  ///
  /// Release builds hand us both forms, so both are rewritten. Only the
  /// constants that stand on their own as an expression are reachable here,
  /// and those sit in the same positions a literal would; a constant that is
  /// part of a larger one - the arguments of a `const` constructor, the
  /// elements of a `const` list - is not an expression at all and is left
  /// alone. Constants are never descended into.
  @override
  TreeNode visitConstantExpression(ConstantExpression node) {
    final Constant constant = node.constant;
    return constant is StringConstant
        ? _visitString(node, constant.value)
        : node;
  }

  TreeNode _visitString(Expression node, String value) {
    if (value.length < minLength) {
      return node;
    }
    final Expression Function(String value)? replace = _replace;
    if (replace == null) {
      values.add(value);
      return node;
    }
    final Expression replacement = replace(value);
    applyFileOffset(
      replacement,
      node.fileOffset == TreeNode.noOffset ? 0 : node.fileOffset,
    );
    return replacement;
  }

  /// Only the body of a function holds code; parameter default values and
  /// annotations have to stay constant.
  @override
  TreeNode visitFunctionNode(FunctionNode node) {
    _visitFunction(node);
    return node;
  }

  /// The expressions of `case 'x':` are constants.
  @override
  TreeNode visitSwitchCase(SwitchCase node) {
    node.body = transform(node.body)..parent = node;
    return node;
  }

  /// Patterns only hold constant expressions and variable declarations.
  @override
  TreeNode defaultPattern(Pattern node) => node;

  /// The initializer of a `const` local has to stay constant.
  @override
  TreeNode visitConstVariable(ConstVariable node) => node;

  /// Annotations on a local have to stay constant; its initializer does not.
  @override
  TreeNode visitLocalVariable(LocalVariable node) {
    final Expression? initializer = node.initializer;
    if (initializer != null) {
      node.initializer = transform(initializer)..parent = node;
    }
    return node;
  }

  @override
  TreeNode visitListLiteral(ListLiteral node) =>
      node.isConst ? node : super.visitListLiteral(node);

  @override
  TreeNode visitSetLiteral(SetLiteral node) =>
      node.isConst ? node : super.visitSetLiteral(node);

  @override
  TreeNode visitMapLiteral(MapLiteral node) =>
      node.isConst ? node : super.visitMapLiteral(node);

  @override
  TreeNode visitStaticInvocation(StaticInvocation node) =>
      node.isConst ? node : super.visitStaticInvocation(node);

  @override
  TreeNode visitConstructorInvocation(ConstructorInvocation node) =>
      node.isConst ? node : super.visitConstructorInvocation(node);
}
