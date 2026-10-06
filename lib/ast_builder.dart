import 'package:kernel/ast.dart';
import 'package:kernel/core_types.dart';

/// Gives every node of [subtree] that has no source location one of [offset].
///
/// Generated code has nowhere to point at, but the kernel verifier - and the
/// stack traces the runtime builds from the snapshot - want a location on
/// every node, so generated nodes borrow the location of whatever they
/// replaced.
void applyFileOffset(TreeNode subtree, int offset) =>
    subtree.accept(_FileOffsetVisitor(offset));

class _FileOffsetVisitor extends RecursiveVisitor {
  _FileOffsetVisitor(this.offset);

  final int offset;

  @override
  void defaultNode(Node node) {
    if (node is TreeNode && node.fileOffset == TreeNode.noOffset) {
      node.fileOffset = offset;
    }
    super.defaultNode(node);
  }
}

/// Builds the handful of kernel expressions the passes need.
///
/// Kernel is explicit where Dart source is not: an `a + b` on two integers is
/// an [InstanceInvocation] of `num::+` carrying the interface target and the
/// function type as seen through the receiver. These helpers keep that
/// bookkeeping in one place, and match what the front end itself emits for
/// the same source.
class AstBuilder {
  AstBuilder(this.coreTypes);

  final CoreTypes coreTypes;

  InterfaceType get intType => coreTypes.intNonNullableRawType;

  InterfaceType get boolType => coreTypes.boolNonNullableRawType;

  InterfaceType get stringType => coreTypes.stringNonNullableRawType;

  InterfaceType get nullableStringType => coreTypes.stringNullableRawType;

  late final InterfaceType intListType = InterfaceType(
    coreTypes.listClass,
    Nullability.nonNullable,
    <DartType>[intType],
  );

  late final Procedure _numAdd = coreTypes.index.getProcedure(
    'dart:core',
    'num',
    '+',
  );
  late final Procedure _numMultiply = coreTypes.index.getProcedure(
    'dart:core',
    'num',
    '*',
  );
  late final Procedure _numLess = coreTypes.index.getProcedure(
    'dart:core',
    'num',
    '<',
  );
  late final Procedure _intAnd = coreTypes.index.getProcedure(
    'dart:core',
    'int',
    '&',
  );
  late final Procedure _intXor = coreTypes.index.getProcedure(
    'dart:core',
    'int',
    '^',
  );
  late final Procedure _intShiftRight = coreTypes.index.getProcedure(
    'dart:core',
    'int',
    '>>',
  );
  late final Procedure _listIndex = coreTypes.index.getProcedure(
    'dart:core',
    'List',
    '[]',
  );
  late final Procedure _listIndexSet = coreTypes.index.getProcedure(
    'dart:core',
    'List',
    '[]=',
  );

  /// The fixed length list factory the front end itself lowers
  /// `List<E>.filled(n, fill)` to.
  ///
  /// The public `List.filled` is never called in a compiled program - the
  /// front end rewrites every call to this one - and a snapshot that has been
  /// through the AOT pipeline no longer resolves it, so generated code has to
  /// use the same factory the rest of the program does.
  late final Procedure _listFilled =
      coreTypes.index.tryGetProcedure('dart:core', '_List', 'filled') ??
      coreTypes.index.getProcedure('dart:core', 'List', 'filled');
  late final Procedure _stringFromCharCodes = coreTypes.index.getProcedure(
    'dart:core',
    'String',
    'fromCharCodes',
  );

  /// `left + right` on integers.
  Expression add(Expression left, Expression right) => _binary(
    left,
    right,
    _numAdd,
    argumentType: coreTypes.numNonNullableRawType,
    result: intType,
  );

  /// `left * right` on integers.
  Expression multiply(Expression left, Expression right) => _binary(
    left,
    right,
    _numMultiply,
    argumentType: coreTypes.numNonNullableRawType,
    result: intType,
  );

  /// `left < right` on integers.
  Expression lessThan(Expression left, Expression right) => _binary(
    left,
    right,
    _numLess,
    argumentType: coreTypes.numNonNullableRawType,
    result: boolType,
  );

  /// `left & right`.
  Expression bitAnd(Expression left, Expression right) =>
      _binary(left, right, _intAnd, argumentType: intType, result: intType);

  /// `left ^ right`.
  Expression bitXor(Expression left, Expression right) =>
      _binary(left, right, _intXor, argumentType: intType, result: intType);

  /// `value >> amount`.
  Expression shiftRight(Expression value, int amount) => _binary(
    value,
    IntLiteral(amount),
    _intShiftRight,
    argumentType: intType,
    result: intType,
  );

  /// `list[index]`, for a `List<int>`.
  Expression intListGet(Expression list, Expression index) =>
      _binary(list, index, _listIndex, argumentType: intType, result: intType);

  /// `list[index] = value`, for a `List<int>`.
  Expression intListSet(Expression list, Expression index, Expression value) =>
      InstanceInvocation(
        InstanceAccessKind.Instance,
        list,
        _listIndexSet.name,
        Arguments(<Expression>[index, value]),
        interfaceTarget: _listIndexSet,
        functionType: FunctionType(
          <DartType>[intType, intType],
          const VoidType(),
          Nullability.nonNullable,
        ),
      );

  /// `List<int>.filled(length, 0)`.
  Expression filledIntList(Expression length) => StaticInvocation(
    _listFilled,
    Arguments(<Expression>[length, IntLiteral(0)], types: <DartType>[intType]),
  );

  /// `String.fromCharCodes(codeUnits)`.
  Expression stringFromCharCodes(Expression codeUnits) => StaticInvocation(
    _stringFromCharCodes,
    Arguments(<Expression>[codeUnits]),
  );

  /// A `const <int>[...]` expression holding [values].
  Expression constIntList(List<int> values) => ConstantExpression(
    ListConstant(
      intType,
      values.map((int value) => IntConstant(value)).toList(growable: false),
    ),
    intListType,
  );

  /// `field ??= value`, for a static `String?` [field], as an expression of
  /// type [stringType].
  ///
  /// This is the same shape the front end lowers `??=` to: read the field
  /// once into a temporary, and only call into [value] when that read was
  /// null.
  Expression cacheString(Field field, Expression value) {
    final cached = SyntheticVariable(
      type: nullableStringType,
      initializer: StaticGet(field),
      isFinal: true,
    );
    return Let(
      cached,
      ConditionalExpression(
        EqualsNull(VariableGet(cached)),
        StaticSet(field, value),
        VariableGet(cached, stringType),
        stringType,
      ),
    );
  }

  Expression _binary(
    Expression receiver,
    Expression argument,
    Procedure target, {
    required DartType argumentType,
    required DartType result,
  }) => InstanceInvocation(
    InstanceAccessKind.Instance,
    receiver,
    target.name,
    Arguments(<Expression>[argument]),
    interfaceTarget: target,
    functionType: FunctionType(
      <DartType>[argumentType],
      result,
      Nullability.nonNullable,
    ),
  );
}
