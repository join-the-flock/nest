/// Runs from Nest after assembling a channel and before publishing it to Flock.
/// Uses the assembled Flutter SDK plus flock-patches to analyze, test, and build
/// a separate flock-demo checkout. Nest's workflow handles publication.
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

String git(Directory repository, List<String> arguments) {
  final command = ['-C', repository.path, ...arguments];
  final result = Process.runSync('git', command);
  if (result.exitCode != 0) {
    throw ProcessException('git', command, '${result.stderr}', result.exitCode);
  }
  return (result.stdout as String).trim();
}

void validateVersion(
  Map<String, dynamic> version, {
  required String revision,
  required String channel,
  required String engine,
}) {
  if (version['frameworkRevision'] != revision) {
    throw StateError(
        'Flutter reported a different revision than the assembled SDK');
  }
  if (version['channel'] != channel) {
    throw StateError('Expected channel $channel, got ${version['channel']}');
  }
  if ([null, '', '0.0.0-unknown'].contains(version['frameworkVersion'])) {
    throw StateError('Flutter could not determine its framework version');
  }
  // Newer SDKs distinguish the engine Git revision from its content hash.
  if (![version['engineRevision'], version['engineContentHash']]
      .contains(engine)) {
    throw StateError(
        'Flutter reported an engine different from the pinned engine');
  }
}

Future<void> validateFlock({
  required Directory sdk,
  required Directory demo,
  required String channel,
  required Directory report,
}) async {
  report.createSync(recursive: true);
  final success = File('${report.path}/success.txt');
  if (success.existsSync()) success.deleteSync();
  final environment = {
    'CI': 'true',
    'FLUTTER_SUPPRESS_ANALYTICS': 'true',
    'DART_SUPPRESS_ANALYTICS': 'true',
  };
  final flutter = '${sdk.path}/bin/flutter';
  final revision = git(sdk, ['rev-parse', 'HEAD']);
  final demoRevision = git(demo, ['rev-parse', 'HEAD']);
  if (!File('${demo.path}/pubspec.yaml').existsSync()) {
    throw StateError('The demo checkout has no pubspec.yaml');
  }
  git(sdk, ['ls-files', '--error-unmatch', 'bin/internal/engine.version']);
  final engine =
      File('${sdk.path}/bin/internal/engine.version').readAsStringSync().trim();
  if (engine.isEmpty)
    throw StateError('The assembled SDK has no pinned engine');
  File('${report.path}/assembly.json').writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({
          'channel': channel,
          'frameworkRevision': revision,
          'pinnedEngine': engine,
          'demoRevision': demoRevision,
        })}\n',
  );

  final log = File('${report.path}/validation.log').openWrite();
  try {
    Future<void> run(List<String> arguments,
        {Directory? cwd, File? output}) async {
      final command = '+ $flutter ${arguments.join(' ')}';
      stdout.writeln(command);
      log.writeln(command);
      final process = await Process.start(
        flutter,
        arguments,
        workingDirectory: (cwd ?? sdk).path,
        environment: environment,
      );
      final target = output?.openWrite();
      try {
        await Future.wait([
          process.stdout.transform(utf8.decoder).forEach((text) {
            if (target != null) {
              target.write(text);
            } else {
              stdout.write(text);
              log.write(text);
            }
          }),
          process.stderr.transform(utf8.decoder).forEach((text) {
            stderr.write(text);
            log.write(text);
          }),
        ]);
        final code = await process.exitCode;
        if (code != 0)
          throw ProcessException(
              flutter, arguments, 'Flutter command failed', code);
      } finally {
        await target?.close();
      }
    }

    // Bootstrap first: fresh SDK downloads can print progress on stdout.
    await run(['--version']);
    final versionFile = File('${report.path}/version.json');
    await run(['--version', '--machine'], output: versionFile);
    validateVersion(
      jsonDecode(versionFile.readAsStringSync()) as Map<String, dynamic>,
      revision: revision,
      channel: channel,
      engine: engine,
    );
    if (File('${sdk.path}/bin/cache/engine.stamp').readAsStringSync().trim() !=
        engine) {
      throw StateError(
          'The downloaded engine does not match the pinned engine');
    }

    // Bypass flock-demo's FVM configuration, which selects the published SDK.
    await run(['pub', 'get'], cwd: demo);
    await run(['analyze', '--no-pub'], cwd: demo);
    await run(['test', '--no-pub'], cwd: demo);
    await run(['build', 'web', '--release', '--no-pub'], cwd: demo);
    if (!File('${demo.path}/build/web/index.html').existsSync()) {
      throw StateError('Web build did not produce build/web/index.html');
    }
    git(sdk, ['diff', '--exit-code', 'HEAD', '--']);
    if (git(sdk, ['rev-parse', 'HEAD']) != revision) {
      throw StateError('The assembled revision changed during validation');
    }
  } finally {
    await log.close();
  }
  success.writeAsStringSync('$channel: validated $revision\n');
  stdout.writeln('$channel: validation passed for $revision');
}

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('flutter-path',
        mandatory: true, help: 'Assembled Flock SDK checkout')
    ..addOption('demo-path',
        mandatory: true, help: 'Matching flock-demo checkout')
    ..addOption('channel',
        mandatory: true, allowed: ['master', 'beta', 'stable'])
    ..addOption('report-dir', mandatory: true)
    ..addFlag('help', abbr: 'h', negatable: false);
  if (arguments.contains('--help') || arguments.contains('-h')) {
    stdout.writeln(
        'Run from Nest before publishing an assembled Flock channel.\n${parser.usage}');
    return;
  }
  try {
    final args = parser.parse(arguments);
    await validateFlock(
      sdk: Directory(args['flutter-path'] as String).absolute,
      demo: Directory(args['demo-path'] as String).absolute,
      channel: args['channel'] as String,
      report: Directory(args['report-dir'] as String).absolute,
    );
  } catch (error) {
    stderr.writeln('Flock validation failed: $error');
    exitCode = 1;
  }
}
