import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'patch_git.dart';

Future<void> runRepairTool(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('flutter',
        abbr: 'f',
        defaultsTo: './flock',
        help: 'Existing fork checkout to repair in place')
    ..addOption('patches-dir', abbr: 'p', help: 'Patch collection directory')
    ..addOption('channel',
        allowed: ['master', 'beta', 'stable'],
        help: 'Patch manifest and fetched origin branch to repair against')
    ..addOption('base',
        help: 'Last-working upstream commit, if no recorded base is available')
    ..addOption('adaptation-date',
        help:
            'UTC date of the upstream change (defaults to target commit date)')
    ..addFlag('continue',
        negatable: false, help: 'Resume after editing conflicts')
    ..addFlag('abort', negatable: false, help: 'Restore the original checkout')
    ..addFlag('export',
        negatable: false,
        help: 'Alias for normal export of a completed repair and new commits')
    ..addFlag('help', abbr: 'h', negatable: false);
  try {
    if (arguments.contains('--help') || arguments.contains('-h')) {
      stdout.writeln(parser.usage);
      return;
    }
    final args = parser.parse(arguments);
    if (args.rest.isNotEmpty)
      throw FormatException('Unexpected positional arguments');
    final actions = ['continue', 'abort', 'export']
        .where((name) => args[name] as bool)
        .toList();
    if (actions.length > 1)
      throw FormatException('Choose one repair operation');
    final repository = p.normalize(p.absolute(args['flutter'] as String));
    if (actions.isNotEmpty) {
      for (final option in [
        'patches-dir',
        'channel',
        'base',
        'adaptation-date'
      ]) {
        if (args.wasParsed(option)) {
          throw FormatException(
              'Resume uses the saved session; omit --$option');
        }
      }
      await resumePatchRepair(repository, actions.single);
    } else {
      if (args['patches-dir'] == null || args['channel'] == null) {
        throw FormatException(
            'Starting a repair requires --patches-dir and --channel');
      }
      await startPatchRepair(
          repository, p.normalize(p.absolute(args['patches-dir'] as String)),
          channel: args['channel'] as String,
          base: args['base'] as String?,
          adaptationDate: args['adaptation-date'] as String?);
    }
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } on FileSystemException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  } on ProcessException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}
