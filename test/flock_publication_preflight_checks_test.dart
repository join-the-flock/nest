// Run from Nest with `dart test`. Tests Nest's publishing gate using controlled
// Flutter command responses and temporary Git repositories, without downloading
// Flutter or contacting flock-demo or the Flock distribution repository.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tools/flock_publication_preflight_checks.dart';

const stages = [
  '--version',
  'version-json',
  'pub-get',
  'analyze',
  'test',
  'build-web'
];

// This program stands in for bin/flutter, so failures can be exercised safely.
const fakeFlutter = r'''
import 'dart:io';
void main(List<String> args) {
  final sdk = File(Platform.script.toFilePath()).parent;
  var stage = args.first == 'build' ? 'build-web' : args.first;
  if (stage == 'pub') stage = 'pub-get';
  if (args.contains('--machine')) stage = 'version-json';
  if (['pub-get', 'analyze', 'test', 'build-web'].contains(stage) &&
      Directory.current.resolveSymbolicLinksSync() !=
          Directory('${sdk.parent.path}/demo').resolveSymbolicLinksSync()) {
    throw StateError('Must run against the demo checkout');
  }
  File('${sdk.path}/calls').writeAsStringSync('$stage\n', mode: FileMode.append);
  final failure = File('${sdk.path}/fail-stage');
  if (failure.existsSync() && failure.readAsStringSync() == stage) exit(7);
  if (stage == '--version' || stage == 'version-json') {
    stdout.write(File('${sdk.path}/version-fixture.json').readAsStringSync());
  } else if (stage == 'build-web') {
    Directory('build/web').createSync(recursive: true);
    File('build/web/index.html').writeAsStringSync('smoke test');
  }
}
''';

String shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

void main() {
  late Directory root;
  late Directory sdk;
  late Directory demo;
  late Directory report;
  late Map<String, dynamic> version;
  final engine = 'a' * 40;

  void write(String path, String contents) {
    final file = File(path)..parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  void commit(Directory repo) {
    git(repo, ['init', '-q']);
    git(repo, ['add', '.']);
    git(repo, [
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.invalid',
      '-c',
      'commit.gpgsign=false',
      'commit',
      '-qm',
      'Fixture',
    ]);
  }

  void writeVersion() =>
      write('${sdk.path}/version-fixture.json', jsonEncode(version));
  List<String> calls() => File('${sdk.path}/calls').readAsLinesSync();
  Future<void> run() =>
      validateFlock(sdk: sdk, demo: demo, channel: 'stable', report: report);
  File success() => File('${report.path}/success.txt');

  setUp(() {
    root = Directory.systemTemp.createTempSync('nest-validation-test-');
    sdk = Directory('${root.path}/sdk')..createSync();
    demo = Directory('${root.path}/demo')..createSync();
    report = Directory('${root.path}/report');
    write('${demo.path}/pubspec.yaml', 'name: flock_demo\n');
    commit(demo);
    write('${sdk.path}/bin/internal/engine.version', '$engine\n');
    write('${sdk.path}/bin/cache/engine.stamp', '$engine\n');
    write('${sdk.path}/fake_flutter.dart', fakeFlutter);
    write(
        '${sdk.path}/bin/flutter',
        '#!/bin/sh\nexec ${shellQuote(Platform.resolvedExecutable)} '
            '${shellQuote('${sdk.path}/fake_flutter.dart')} "\$@"\n');
    final mode = Process.runSync('chmod', ['+x', '${sdk.path}/bin/flutter']);
    expect(mode.exitCode, 0);
    commit(sdk);
    version = {
      'frameworkRevision': git(sdk, ['rev-parse', 'HEAD']),
      'frameworkVersion': '3.47.9',
      'channel': 'stable',
      'engineRevision': engine,
    };
    writeVersion();
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('success requires every demo check and records its revision', () async {
    await run();
    expect(calls(), stages);
    expect(success().existsSync(), isTrue);
    final evidence =
        jsonDecode(File('${report.path}/assembly.json').readAsStringSync());
    expect(evidence['demoRevision'], git(demo, ['rev-parse', 'HEAD']));
  });

  for (final field in [
    'frameworkRevision',
    'channel',
    'engineRevision',
    'frameworkVersion'
  ]) {
    test('rejects an incorrect $field before running the demo', () async {
      version[field] = field == 'frameworkVersion' ? '0.0.0-unknown' : 'wrong';
      writeVersion();
      await expectLater(run(), throwsStateError);
      expect(calls(), stages.take(2).toList());
      expect(success().existsSync(), isFalse);
    });
  }

  test('accepts engines identified by content hash', () async {
    version.addAll({'engineRevision': 'b' * 40, 'engineContentHash': engine});
    writeVersion();
    await run();
    expect(success().existsSync(), isTrue);
  });

  for (final stage in stages) {
    test('$stage failure stops later checks and clears stale success',
        () async {
      write('${report.path}/success.txt', 'previous run');
      write('${sdk.path}/fail-stage', stage);
      await expectLater(run(), throwsA(isA<ProcessException>()));
      expect(calls(), stages.take(stages.indexOf(stage) + 1).toList());
      expect(success().existsSync(), isFalse);
    });
  }

  test('rejects a downloaded engine that differs from the pin', () async {
    write('${sdk.path}/bin/cache/engine.stamp', 'wrong');
    await expectLater(run(), throwsStateError);
    expect(calls(), stages.take(2).toList());
  });

  test('rejects tracked source changes during validation', () async {
    File('${sdk.path}/bin/flutter')
        .writeAsStringSync('\n# Changed source\n', mode: FileMode.append);
    await expectLater(run(), throwsA(isA<ProcessException>()));
    expect(success().existsSync(), isFalse);
  });
}
