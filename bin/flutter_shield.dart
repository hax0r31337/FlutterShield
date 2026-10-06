import 'dart:io';

void main(List<String> arguments) {
  if (arguments.length != 2) {
    stderr.writeln('usage: flutter_shield <input.dill> <output.dill>');
    exit(64);
  }
  final input = File(arguments[0]);
  final output = File(arguments[1]);

  if (!input.existsSync()) {
    stderr.writeln('flutter_shield: input dill not found: ${input.path}');
    exit(66);
  }

  // TODO: process the kernel snapshot. For now pass it through unchanged.
  output.parent.createSync(recursive: true);
  input.copySync(output.path);
}
