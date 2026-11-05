import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  const actions = [
    'assemble-fork',
    'publish-fork',
    'build-and-upload-engine',
    'run-framework-tests'
  ];
  group('Reusable fork action contracts >', () {
    for (final name in actions) {
      test(
          '$name has no fork-specific runtime assumptions and declares its inputs',
          () async {
        final file = File('.github/actions/$name/action.yaml');
        final text = file.readAsStringSync();
        final action = _action(name);
        final inputs = action['inputs'] as YamlMap;
        // Documentation can mention particular forks as examples. Check the
        // executable configuration and defaults, rather than prose or comments.
        final configuration = {
          'inputs': {
            for (final entry in inputs.entries)
              entry.key: {
                for (final field in (entry.value as YamlMap).entries)
                  if (field.key != 'description') field.key: field.value,
              },
          },
          'runs': action['runs'],
        }.toString();
        expect(configuration,
            isNot(matches(RegExp(r'\bflock\b', caseSensitive: false))));
        expect(configuration, isNot(contains('matrix.')));
        for (final reference in RegExp(r'inputs\.([a-z_]+)').allMatches(text)) {
          expect(inputs.containsKey(reference[1]), isTrue,
              reason: reference[0]);
        }
        for (final step
            in _steps(action).where((step) => step['run'] != null)) {
          final syntax =
              await Process.run('bash', ['-n', '-c', step['run'] as String]);
          expect(syntax.exitCode, 0,
              reason: '${step['name']}: ${syntax.stderr}');
        }
      });
    }

    test('every local action caller resolves and supplies its required inputs',
        () {
      var calls = 0;
      for (final file
          in Directory('.github/workflows').listSync().whereType<File>()) {
        final workflow = loadYaml(file.readAsStringSync()) as YamlMap;
        for (final job
            in (workflow['jobs'] as YamlMap).values.cast<YamlMap>()) {
          for (final step in (job['steps'] as YamlList).cast<YamlMap>()) {
            final uses = step['uses'];
            if (uses is! String || !uses.startsWith('./.github/actions/'))
              continue;
            calls++;
            final action =
                loadYaml(File('$uses/action.yaml').readAsStringSync())
                    as YamlMap;
            final declarations = action['inputs'] as YamlMap;
            final supplied = step['with'] as YamlMap? ?? YamlMap();
            for (final entry in declarations.entries) {
              final spec = entry.value as YamlMap;
              if (spec['required'] == true && spec['default'] == null) {
                expect(supplied.containsKey(entry.key), isTrue,
                    reason: '${file.path}: $uses requires ${entry.key}');
              }
            }
            for (final key in supplied.keys) {
              expect(declarations.containsKey(key), isTrue,
                  reason: '${file.path}: $uses does not declare $key');
            }
          }
        }
      }
      expect(calls, greaterThan(0));
    });

    test('CI covers changes to every reusable action', () {
      final workflow = loadYaml(
              File('.github/workflows/test-nest-tools.yaml').readAsStringSync())
          as YamlMap;
      for (final event in ['push', 'pull_request']) {
        final config = (workflow['on'] as YamlMap)[event] as YamlMap;
        expect(config['paths'], contains('.github/actions/**'));
      }
    });
  });

  group('Reusable fork action execution >', () {
    late Directory root;
    setUp(() {
      root = Directory(Directory.systemTemp
          .createTempSync('nest-action-tests-')
          .resolveSymbolicLinksSync());
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('assembly uses custom checkout paths and local Git identity',
        () async {
      final inputs = <String, String>{
        'fork_path': 'custom sdk',
        'patches_path': 'custom patches',
        'patches_manifest': '.patches-stable',
        'git_user_name': 'Example Maintainer',
        'git_user_email': 'maintainer@example.invalid',
      };
      final sdk = Directory('${root.path}/${inputs['fork_path']}')
        ..createSync();
      await _initialize(sdk);
      _write('${sdk.path}/.gitignore', 'bin/cache/\n');
      _write('${sdk.path}/base.txt', 'base\n');
      _write('${sdk.path}/bin/internal/update_engine_version.sh',
          '#!/bin/sh\nmkdir -p bin/cache\nprintf "pinned-engine\\n" > bin/cache/engine.stamp\n');
      await _executable('${sdk.path}/bin/internal/update_engine_version.sh');
      await _commit(sdk, 'Base');
      final patches = Directory('${root.path}/${inputs['patches_path']}')
        ..createSync();
      _write('${patches.path}/.patches-stable', 'feature.patch\n');
      _write('${patches.path}/feature.patch',
          '''From ${'0' * 40} Mon Sep 17 00:00:00 2001
From: Patch Author <patch@example.invalid>
Date: Wed, 4 Nov 2026 12:00:00 -0500
Subject: Add feature

---
diff --git a/feature.txt b/feature.txt
new file mode 100644
--- /dev/null
+++ b/feature.txt
@@ -0,0 +1 @@
+feature
''');
      await _run('assemble-fork', 'Save engine hash', root, inputs);
      expect(await _git(sdk, ['log', '-1', '--format=%an <%ae>']),
          'Example Maintainer <maintainer@example.invalid>');
      expect(await _git(sdk, ['config', '--local', 'user.name']),
          'Example Maintainer');
      expect(File('${sdk.path}/bin/internal/engine.version').readAsStringSync(),
          'pinned-engine\n');
      final engineCommit = await _git(sdk, ['rev-parse', 'HEAD']);
      await _run('assemble-fork', 'Apply fork patches', root, inputs);
      expect(File('${sdk.path}/feature.txt').readAsStringSync(), 'feature\n');
      expect(await _git(sdk, ['rev-parse', 'refs/patches/upstream-head']),
          engineCommit);
      expect(await _git(sdk, ['log', '-1', '--format=%cn <%ce>']),
          'Example Maintainer <maintainer@example.invalid>');
      expect(await _git(sdk, ['status', '--porcelain']), isEmpty);
    });

    for (final absolute in [false, true]) {
      test('framework tests use the selected SDK (absolute path=$absolute)',
          () async {
        final sdk = Directory('${root.path}/custom sdk')..createSync();
        Directory('${sdk.path}/packages/flutter').createSync(recursive: true);
        _write('${sdk.path}/bin/flutter',
            '#!/bin/sh\nprintf "%s|%s\\n" "\$*" "\$PWD" >> "\$ACTION_TEST_LOG"\n');
        await _executable('${sdk.path}/bin/flutter');
        final global = Directory('${root.path}/global-bin')..createSync();
        _write('${global.path}/flutter', '#!/bin/sh\nexit 99\n');
        await _executable('${global.path}/flutter');
        final log = File('${root.path}/commands.log');
        await _run('run-framework-tests', 'Run tests', root, {
          'flutter_path': absolute ? sdk.path : 'custom sdk'
        }, extra: {
          'ACTION_TEST_LOG': log.path,
          'PATH': '${global.path}:${Platform.environment['PATH']}'
        });
        final lines = log.readAsLinesSync();
        expect(lines.first, startsWith('update-packages|'));
        expect(lines.last, 'test|${sdk.path}/packages/flutter');
      });
    }

    test('engine steps build and upload from a custom SDK and bucket',
        () async {
      final inputs = {
        'fork_path': 'engine sdk',
        'gclient': 'custom-linux',
        'config_name': 'ci/custom_release',
        'gcp_bucket': 'example-builds',
        'engine_version': 'engine-123'
      };
      final sdk = Directory('${root.path}/${inputs['fork_path']}')
        ..createSync();
      final engine = Directory('${sdk.path}/engine/src')
        ..createSync(recursive: true);
      _write(
          '${sdk.path}/engine/scripts/custom-linux.gclient', 'custom config\n');
      _write('${engine.path}/flutter/bin/et',
          '#!/bin/sh\nprintf "et:%s|%s\\n" "\$*" "\$PWD" >> "\$ACTION_TEST_LOG"\n');
      await _executable('${engine.path}/flutter/bin/et');
      final tools = Directory('${root.path}/stub-tools')..createSync();
      for (final command in ['gclient', 'gcloud']) {
        _write('${tools.path}/$command',
            '#!/bin/sh\nprintf "$command:%s|%s\\n" "\$*" "\$PWD" >> "\$ACTION_TEST_LOG"\n');
        await _executable('${tools.path}/$command');
      }
      final log = File('${root.path}/commands.log');
      final extra = {
        'ACTION_TEST_LOG': log.path,
        'PATH': '${tools.path}:${Platform.environment['PATH']}'
      };
      for (final step in [
        'Copy gclient file',
        'Gclient sync',
        'Fetch engine dependencies',
        'Build engine'
      ]) {
        await _run('build-and-upload-engine', step, root, inputs, extra: extra);
      }
      expect(
          File('${sdk.path}/.gclient').readAsStringSync(), 'custom config\n');
      expect(log.readAsStringSync(),
          contains('et:build --config ci/custom_release|${engine.path}'));
      _write('${engine.path}/out/ci/custom_release/zip_archives/engine.zip',
          'archive');
      await _run('build-and-upload-engine', 'Copy zip archives', root, inputs,
          extra: extra);
      expect(
          log.readAsStringSync(),
          contains(
              'gs://example-builds/flutter_infra_release/flutter/engine/engine-123/'));
      Directory('${engine.path}/out/ci/custom_release/zip_archives')
          .deleteSync(recursive: true);
      _write('${engine.path}/out/ci/custom_release/engine.bin', 'output');
      await _run('build-and-upload-engine', 'Copy engine outputs', root, inputs,
          extra: extra);
      expect(File('${engine.path}/out/ci/custom_release.tar.gz').lengthSync(),
          greaterThan(0));
      expect(log.readAsStringSync(),
          contains('engine-123/ci/custom_release.tar.gz'));
    });

    test(
        'publication force-pushes the selected checkout and branch to a local test remote',
        () async {
      final sdk = Directory('${root.path}/custom sdk')..createSync();
      final remote = Directory('${root.path}/remote.git')..createSync();
      await _initialize(sdk);
      await _git(remote, ['init', '--bare', '-q']);
      _write('${sdk.path}/.gitignore', 'bin/cache/\n');
      _write('${sdk.path}/base.txt', 'base\n');
      await _commit(sdk, 'Base');
      final base = await _git(sdk, ['rev-parse', 'HEAD']);
      _write('${sdk.path}/remote.txt', 'remote history\n');
      await _commit(sdk, 'Remote history');
      await _git(sdk, ['push', remote.path, 'HEAD:refs/heads/release/custom']);
      await _git(sdk, ['reset', '--hard', base]);
      _write('${sdk.path}/feature.txt', 'fork history\n');
      await _commit(sdk, 'Fork history');
      final head = await _git(sdk, ['rev-parse', 'HEAD']);
      final branch = await _git(sdk, ['branch', '--show-current']);
      await _git(sdk, [
        'config',
        'url.${remote.uri}.insteadOf',
        'https://github.com/example/fork'
      ]);
      await _run('publish-fork', 'Push to destination', root, {
        'fork_path': 'custom sdk',
        'destination_repo': 'example/fork',
        'destination_branch': 'release/custom'
      });
      expect(
          await _git(remote, ['rev-parse', 'refs/heads/release/custom']), head);
      expect(await _git(sdk, ['branch', '--show-current']), branch);
    });
  });
}

YamlMap _action(String name) =>
    loadYaml(File('.github/actions/$name/action.yaml').readAsStringSync())
        as YamlMap;
List<YamlMap> _steps(YamlMap action) =>
    ((action['runs'] as YamlMap)['steps'] as YamlList).cast<YamlMap>().toList();

Future<void> _run(
    String action, String name, Directory workspace, Map<String, String> inputs,
    {Map<String, String> extra = const {}}) async {
  final step =
      _steps(_action(action)).singleWhere((step) => step['name'] == name);
  String render(String value) => value.replaceAllMapped(
          RegExp(
              r'\$\{\{\s*(inputs\.([a-z_]+)|github\.workspace|github\.action_path)\s*\}\}'),
          (match) {
        if (match[2] != null) return inputs[match[2]]!;
        if (match[1] == 'github.workspace') return workspace.path;
        return '${Directory.current.path}/.github/actions/$action';
      });
  final environment = <String, String>{
    for (final entry in (step['env'] as YamlMap? ?? YamlMap()).entries)
      entry.key as String: render(entry.value as String),
    ...extra,
  };
  environment['PATH'] =
      '${File(Platform.resolvedExecutable).parent.path}:${extra['PATH'] ?? Platform.environment['PATH']}';
  final result = await Process.run('bash', ['-c', step['run'] as String],
      workingDirectory:
          render(step['working-directory'] as String? ?? workspace.path),
      environment: environment);
  expect(result.exitCode, 0,
      reason: '$action / $name: ${result.stdout}\n${result.stderr}');
}

void _write(String path, String contents) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

Future<void> _executable(String path) async {
  expect((await Process.run('chmod', ['+x', path])).exitCode, 0);
}

Future<void> _initialize(Directory repo) async {
  await _git(repo, ['init', '-q']);
  for (final setting in {
    'user.name': 'Fixture author',
    'user.email': 'fixture@example.invalid',
    'commit.gpgsign': 'false',
    'core.hooksPath': '/dev/null'
  }.entries) {
    await _git(repo, ['config', setting.key, setting.value]);
  }
}

Future<void> _commit(Directory repo, String message) async {
  await _git(repo, ['add', '.']);
  await _git(repo, ['commit', '-qm', message]);
}

Future<String> _git(Directory repo, List<String> args) async {
  final result = await Process.run('git', ['-C', repo.path, ...args]);
  expect(result.exitCode, 0, reason: '$args: ${result.stderr}');
  return (result.stdout as String).trim();
}
