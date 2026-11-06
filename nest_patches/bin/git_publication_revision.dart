import 'dart:io';
import 'package:args/args.dart';
import 'package:nest_patches/nest_patches.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()..addOption('flutter', mandatory: true);
  try {
    final args = parser.parse(arguments);
    stdout.writeln(await publicationRevision(
        Directory(args['flutter'] as String).absolute.path));
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}
