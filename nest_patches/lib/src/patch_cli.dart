import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'patch_collection.dart';
import 'patch_git.dart';

/// Shared command handling for the import and export entry points.
Future<void> runPatchTool(List<String> arguments,
    {required bool importing}) async {
  final parser = ArgParser()
    ..addOption('flutter',
        abbr: 'f',
        defaultsTo: './flock',
        help: 'Git repository to patch or export')
    ..addOption('patches-dir',
        abbr: 'p', mandatory: true, help: 'Patch collection directory')
    ..addOption('channel',
        allowed: ['master', 'beta', 'stable'],
        help: 'Select a channel manifest')
    ..addOption('manifest',
        help: 'Select .patches or an explicit channel manifest')
    ..addFlag('help', abbr: 'h', negatable: false);
  if (importing) {
    parser.addFlag('3way',
        abbr: '3', negatable: false, help: 'Use three-way merging');
  } else {
    parser
      ..addOption('grep',
          help: 'Export complete patch files matching this text')
      ..addFlag('update-shared',
          negatable: false, help: 'Allow changes to shared patches')
      ..addFlag('dry-run',
          negatable: false, help: 'Report pending changes without writing');
  }
  try {
    // Help should not require the mandatory collection argument.
    if (arguments.contains('--help') || arguments.contains('-h')) {
      stdout.writeln(parser.usage);
      return;
    }
    final args = parser.parse(arguments);
    if (args['channel'] != null && args['manifest'] != null) {
      throw FormatException('Select either --channel or --manifest, not both');
    }
    if (args.rest.length > (importing ? 0 : 1)) {
      throw FormatException('Unexpected positional arguments');
    }
    final directory = _absolute(args['patches-dir'] as String);
    final repository = _absolute(args['flutter'] as String);
    final manifest = args['channel'] != null
        ? '.patches-${args['channel']}'
        : args['manifest'] as String?;
    if (importing) {
      final selection = resolveManifest(directory, manifest);
      // Read and validate all inputs before recording the upstream revision.
      final data = readPatchCollection(directory, selection);
      await importPatches(repository, data, threeway: args['3way'] as bool);
    } else {
      await exportPatches(repository, directory,
          patchRange: args.rest.isEmpty ? null : args.rest.single,
          manifest: manifest,
          grep: args['grep'] as String?,
          updateShared: args['update-shared'] as bool,
          dryRun: args['dry-run'] as bool);
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

String _absolute(String path) {
  if (path == '~' || path.startsWith('~/')) {
    final home = Platform.environment['HOME'];
    if (home == null)
      throw FormatException('Cannot expand home directory: $path');
    path = p.join(home, path == '~' ? '' : path.substring(2));
  }
  final directory = Directory(p.normalize(p.absolute(path)));
  return directory.existsSync()
      ? directory.resolveSymbolicLinksSync()
      : directory.path;
}
