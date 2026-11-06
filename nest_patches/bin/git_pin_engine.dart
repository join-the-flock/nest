import 'dart:io';
import 'package:args/args.dart';
import 'package:nest_patches/nest_patches.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('flutter', mandatory: true)
    ..addOption('engine-version');
  try {
    final args = parser.parse(arguments);
    final repository = Directory(args['flutter'] as String).absolute.path;
    stdout.writeln(await pinEngine(repository,
        version: args['engine-version'] as String?));
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}
