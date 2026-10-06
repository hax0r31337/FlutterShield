import 'dart:math';

import 'package:kernel/ast.dart';
import 'package:vm/transformations/type_flow/utils.dart'
    show mayHaveSideEffects;

import '../pass.dart';

/// Permutes the order in which the classes of the selected libraries declare
/// their fields.
///
/// No Dart program can read the declaration order back out, but the VM lays
/// its objects out in it: `ClassFinalizer::AssignFieldOffsets` walks the field
/// array of a class in declaration order and hands out the slots of an
/// instance in that order. In AOT code a field access is nothing but that
/// slot - with `--obfuscate` the names are gone, and the fields of a class
/// show up only as a set of offsets off the object pointer - so the order is
/// what a reader of the snapshot has to match back up against the source, and
/// against the other classes of the program. Shuffling it costs nothing at
/// runtime, because the offsets are resolved when the snapshot is built
/// either way.
///
/// There is one thing the declaration order decides besides the layout, and
/// the pass leaves that alone: a constructor runs the initializers of the
/// instance fields that declare one in declaration order, and such an
/// initializer can have side effects. On the snapshot this tool is pointed at
/// no field is in that position any more - the type flow analysis has already
/// hoisted those initializers into the constructors - but the pass checks
/// rather than assumes, see [_isOrderSensitive].
class FieldShufflePass extends ObfuscationPass {
  const FieldShufflePass({this.seed});

  /// Fixed seed, for a reproducible build. The randomness of the pass context
  /// is used when this is null.
  final int? seed;

  @override
  String get name => 'field-shuffle';

  @override
  void run(PassContext context) {
    final Random random = seed == null ? context.random : Random(seed!);

    int shuffled = 0;
    int considered = 0;
    int moved = 0;
    int pinned = 0;
    for (final Library library in context.libraries) {
      for (final Class node in library.classes) {
        final List<Field> fields = node.fields;
        if (fields.length < 2 || _laysOutMemory(node)) {
          continue;
        }
        considered++;
        pinned += fields.where(_isOrderSensitive).length;
        final int displaced = _shuffle(fields, random);
        if (displaced != 0) {
          shuffled++;
          moved += displaced;
        }
      }
    }

    context.log(
      'field-shuffle: $shuffled of $considered classes reordered, '
      '$moved fields moved, $pinned kept in order for their initializers',
    );
  }
}

/// Reorders [fields] in place and reports how many of them ended up somewhere
/// else than they started.
///
/// The permutation is a plain Fisher-Yates shuffle, with the order sensitive
/// fields written back into whichever slots the shuffle gave them, in their
/// original relative order. A shuffle is a permutation, so there are always as
/// many such slots as there are fields to put in them.
int _shuffle(List<Field> fields, Random random) {
  final List<Field> order = List<Field>.of(fields);
  for (int i = order.length - 1; i > 0; i--) {
    final int j = random.nextInt(i + 1);
    final Field held = order[i];
    order[i] = order[j];
    order[j] = held;
  }

  final List<Field> sensitive = fields
      .where(_isOrderSensitive)
      .toList(growable: false);
  if (sensitive.isNotEmpty) {
    int next = 0;
    for (int i = 0; i < order.length; i++) {
      if (_isOrderSensitive(order[i])) {
        order[i] = sensitive[next++];
      }
    }
  }

  int displaced = 0;
  for (int i = 0; i < order.length; i++) {
    if (!identical(order[i], fields[i])) {
      displaced++;
    }
  }
  if (displaced != 0) {
    fields.setAll(0, order);
  }
  return displaced;
}

/// Whether moving [field] could change what the program does.
///
/// A constructor evaluates the initializers of the instance fields that
/// declare one, in declaration order, before its own body runs, so two such
/// initializers can tell which of them went first. A static field - and a
/// `late` one - is initialized on first read instead, so its place in the
/// declaration order is never evaluated at all.
///
/// The condition is the one the type flow analysis itself applies, down to the
/// `mayHaveSideEffects` it decides with: `MoveFieldInitializers` of
/// `package:vm` hoists exactly these initializers into the initializer list of
/// every constructor of the class and clears [Field.initializer]. That list is
/// an evaluation order of its own, and this pass does not touch it, so on a
/// snapshot that has been through the analysis - which a release snapshot has,
/// and what the field initializers of one still hold is a constant the VM
/// stores into the instance directly - this never holds and nothing is ever
/// held back. The check is here so that the pass is also correct on a snapshot
/// that has not, such as the output of a bare `dart compile kernel`.
bool _isOrderSensitive(Field field) {
  if (field.isStatic || field.isLate) {
    return false;
  }
  final Expression? initializer = field.initializer;
  return initializer != null && mayHaveSideEffects(initializer);
}

/// Whether the declaration order of the fields of [node] is the memory layout
/// of something outside the snapshot.
///
/// A `dart:ffi` compound describes a C struct or union, where the order of the
/// fields *is* the ABI; shuffling it would quietly rewrite the layout the
/// native side on the other end still expects. The release snapshot this tool
/// is pointed at has already been through the front end's ffi transformation,
/// which replaces the fields of a compound with accessors that load from a
/// computed offset and leaves no instance fields behind - but a snapshot that
/// has not, such as the output of a bare `dart compile kernel`, still declares
/// them, so they are recognized rather than assumed away.
bool _laysOutMemory(Class node) {
  for (Class? current = node; current != null; current = current.superclass) {
    if (current.enclosingLibrary.importUri.toString() == 'dart:ffi' &&
        const <String>{
          'Struct',
          'Union',
          'AbiSpecificInteger',
        }.contains(current.name)) {
      return true;
    }
  }
  return false;
}
