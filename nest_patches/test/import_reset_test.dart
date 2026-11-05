import 'dart:io';

import 'package:nest_patches/nest_patches.dart';
import 'package:test/test.dart';

void main() {
  group('Import history and reset >', () {
    late Directory root, source, target, patches;
    late String base, assembled;
    setUp(() async {
      root = Directory.systemTemp.createTempSync('nest-reset-tests-');
      source = Directory('${root.path}/source')..createSync();
      target = Directory('${root.path}/target');
      patches = Directory('${root.path}/patches')..createSync();
      await _git(source, ['init', '-q']);
      await _configure(source);
      _write(source, '.gitignore', 'cache/\n');
      _write(source, 'base.txt', 'base\n');
      _write(source, 'README.md', 'upstream readme\n');
      await _commit(source, 'Base');
      base = await _git(source, ['rev-parse', 'HEAD']);
      await _git(source, ['update-ref', upstreamHead, base]);
      _write(source, 'feature.txt', 'first feature\n');
      await _commit(source, 'Feature\n\nPatch-Filename: feature.patch');
      await _success(await _tool('export', source, patches));
      final clone = await Process.run('git',
          ['clone', '--shared', '--no-checkout', source.path, target.path]);
      expect(clone.exitCode, 0, reason: '${clone.stderr}');
      await _git(target, ['checkout', '--detach', base]);
      await _configure(target);
      await _success(await _tool('import', target, patches));
      assembled = await _git(target, ['rev-parse', 'HEAD']);
    });
    tearDown(() => root.deleteSync(recursive: true));

    Future<void> updateFeature() async {
      _write(source, 'feature.txt', 'updated feature\n');
      await _git(source, ['add', '.']);
      await _git(source, ['commit', '--amend', '--no-edit', '-q']);
      await _success(await _tool('export', source, patches));
    }

    Future<void> rejects(
        {List<String> options = const ['--reset'], String? error}) async {
      final head = await _git(target, ['rev-parse', 'HEAD']);
      final tree = await _git(target, ['write-tree']);
      final refs = await _git(target, ['show-ref']);
      final status = await _git(
          target, ['status', '--porcelain', '--untracked-files=all']);
      final result = await _tool('import', target, patches, options);
      expect(result.exitCode, isNot(0), reason: '${result.stdout}');
      if (error != null) expect(result.stderr, contains(error));
      expect(await _git(target, ['rev-parse', 'HEAD']), head);
      expect(await _git(target, ['write-tree']), tree);
      expect(await _git(target, ['show-ref']), refs);
      expect(
          await _git(
              target, ['status', '--porcelain', '--untracked-files=all']),
          status);
    }

    Future<void> failedAtBase(ProcessResult result) async {
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('no patches remain applied'));
      expect(result.stderr, contains(base));
      expect(await _git(target, ['rev-parse', 'HEAD']), base);
      expect(await _git(target, ['rev-parse', upstreamHead]), base);
      expect(await _git(target, ['write-tree']),
          await _git(target, ['rev-parse', '$base^{tree}']));
      expect(await _git(target, ['status', '--porcelain']), isEmpty);
      expect(File('${target.path}/feature.txt').existsSync(), isFalse);
      final backups = await _backups(target);
      expect(backups, hasLength(1));
      expect(await _git(target, ['rev-parse', backups.single]), assembled);
      final gitDirectory =
          await _git(target, ['rev-parse', '--absolute-git-dir']);
      expect(Directory('$gitDirectory/rebase-apply').existsSync(), isFalse);
    }

    for (final threeway in [false, true]) {
      test(
          'a later conflicting patch rolls back the entire reset/import (3way=$threeway)',
          () async {
        final first = File('${patches.path}/feature.patch').readAsStringSync();
        File('${patches.path}/conflict.patch')
            .writeAsStringSync(_conflictingMail(first));
        File('${patches.path}/.patches-master')
            .writeAsStringSync('feature.patch\nconflict.patch\n');
        _write(target, 'cache/sdk.bin', 'cached SDK\n');
        final result = await _tool(
            'import', target, patches, ['--reset', if (threeway) '-3']);
        expect(result.stdout, contains('Applying: Feature'));
        await failedAtBase(result);
        expect(File('${target.path}/cache/sdk.bin').readAsStringSync(),
            'cached SDK\n');
        File('${patches.path}/.patches-master')
            .writeAsStringSync('feature.patch\n');
        await _success(await _tool('import', target, patches));
        expect(File('${target.path}/feature.txt').readAsStringSync(),
            'first feature\n');
      });
    }

    test(
        'replacement translation conflicts also leave the checkout at upstream',
        () async {
      _write(source, 'README.md', 'replacement readme\n');
      await _commit(source,
          'README\n\nPatch-Replace-File: README.md\nPatch-Filename: readme.patch');
      await _success(await _tool('export', source, patches));
      final first = File('${patches.path}/feature.patch').readAsStringSync();
      File('${patches.path}/conflict.patch')
          .writeAsStringSync(_conflictingMail(first));
      File('${patches.path}/.patches-master')
          .writeAsStringSync('feature.patch\nreadme.patch\nconflict.patch\n');
      await failedAtBase(await _tool('import', target, patches, ['--reset']));
      expect(File('${target.path}/README.md').readAsStringSync(),
          'upstream readme\n');
    });

    test(
        'normal import refuses an existing assembled stack and preserves its upstream ref',
        () async {
      await rejects(options: [], error: '--reset');
      expect(await _git(target, ['rev-parse', upstreamHead]), base);
    });

    test(
        'normal import also detects imported history without the private base ref',
        () async {
      await _git(target, ['update-ref', '-d', upstreamHead]);
      await rejects(options: [], error: 'Imported patch history');
    });

    test('normal import accepts a fresh checkout at the recorded base',
        () async {
      await _git(target, ['reset', '--hard', base]);
      await _success(await _tool('import', target, patches));
      expect(File('${target.path}/feature.txt').readAsStringSync(),
          'first feature\n');
      expect(await _backups(target), isEmpty);
    });

    test(
        'normal import refuses manually authored commits after the recorded base',
        () async {
      await _git(target, ['reset', '--hard', base]);
      _write(target, 'manual.txt', 'local commit\n');
      await _commit(target, 'A manually authored fork change');
      await rejects(options: [], error: 'HEAD differs');
    });

    test('reset rebuilds changed patches and backs up unexported commits',
        () async {
      _write(target, 'unexported.txt', 'recoverable work\n');
      await _commit(target, 'Unexported work');
      final previous = await _git(target, ['rev-parse', 'HEAD']);
      await updateFeature();
      final result = await _tool('import', target, patches, ['--reset', '-3']);
      await _success(result);
      final backups = await _backups(target);
      expect(backups, hasLength(1));
      expect(result.stdout, contains(backups.single));
      expect(await _git(target, ['rev-parse', backups.single]), previous);
      expect(await _git(target, ['show', '${backups.single}:unexported.txt']),
          'recoverable work');
      expect(File('${target.path}/unexported.txt').existsSync(), isFalse);
      expect(File('${target.path}/feature.txt').readAsStringSync(),
          'updated feature\n');
      expect(await _git(target, ['rev-parse', upstreamHead]), base);
      expect(await _git(target, ['rev-list', '--count', '$base..HEAD']), '1');
      expect(await _git(target, ['status', '--porcelain']), isEmpty);
      await _success(await _tool('export', target, patches, ['--dry-run']));
    });

    test(
        'repeated resets preserve distinct backups without stacking duplicate patches',
        () async {
      await _success(await _tool('import', target, patches, ['--reset']));
      final afterFirst = await _git(target, ['rev-parse', 'HEAD']);
      await _success(await _tool('import', target, patches, ['--reset']));
      final backups = await _backups(target);
      expect(backups, hasLength(2));
      expect(await _git(target, ['rev-parse', backups.first]), assembled);
      expect(await _git(target, ['rev-parse', backups.last]), afterFirst);
      expect(await _git(target, ['rev-list', '--count', '$base..HEAD']), '1');
    });

    test('reset works at the recorded base with no applied commits', () async {
      await _git(target, ['reset', '--hard', base]);
      await _success(await _tool('import', target, patches, ['--reset']));
      expect(await _git(target, ['rev-list', '--count', '$base..HEAD']), '1');
      expect(await _git(target, ['rev-parse', (await _backups(target)).single]),
          base);
    });

    test('reset replays multiple commits in one patch file in order', () async {
      _write(source, 'feature.txt', 'second feature\n');
      await _commit(source, 'Second feature\n\nPatch-Filename: feature.patch');
      await _success(await _tool('export', source, patches));
      await _success(await _tool('import', target, patches, ['--reset']));
      expect(File('${target.path}/feature.txt').readAsStringSync(),
          'second feature\n');
      expect(await _git(target, ['rev-list', '--count', '$base..HEAD']), '2');
    });

    test('reset supports replacement patches and preserves their metadata',
        () async {
      _write(source, 'README.md', 'replacement readme\n');
      await _commit(source,
          'README\n\nPatch-Replace-File: README.md\nPatch-Filename: readme.patch');
      await _success(await _tool('export', source, patches));
      _write(target, 'README.md', 'local committed readme\n');
      await _commit(target, 'Local README');
      await _success(await _tool('import', target, patches, ['--reset', '-3']));
      expect(File('${target.path}/README.md').readAsStringSync(),
          'replacement readme\n');
      expect(await _git(target, ['log', '-1', '--format=%B']),
          contains('Patch-Replace-File: README.md'));
      expect(await _git(target, ['rev-list', '--count', '$base..HEAD']), '2');
      await _success(await _tool('export', target, patches, ['--dry-run']));
    });

    test(
        'reset selects the requested manifest without changing the upstream revision',
        () async {
      _write(source, 'feature.txt', 'stable feature\n');
      await _git(source, ['add', '.']);
      await _git(source, [
        'commit',
        '--amend',
        '-qm',
        'Stable feature\n\nPatch-Filename: feature_2026-11-04.patch'
      ]);
      await _success(
          await _tool('export', source, patches, ['--channel', 'stable']));
      await _success(await _tool(
          'import', target, patches, ['--reset', '--channel', 'stable']));
      expect(File('${target.path}/feature.txt').readAsStringSync(),
          'stable feature\n');
      expect(await _git(target, ['rev-parse', upstreamHead]), base);
    });

    test('reset leaves ignored SDK caches untouched', () async {
      _write(target, 'cache/sdk.bin', 'cached SDK\n');
      await _success(await _tool('import', target, patches, ['--reset']));
      expect(File('${target.path}/cache/sdk.bin').readAsStringSync(),
          'cached SDK\n');
    });

    test('reset validates committer identity before changing history',
        () async {
      await _git(target, ['config', 'user.name', '']);
      await rejects();
    });

    test('a hook rejecting a later commit rolls back earlier applied commits',
        () async {
      _write(source, 'feature.txt', 'second feature\n');
      await _commit(
          source, 'Rejected second patch\n\nPatch-Filename: feature.patch');
      await _success(await _tool('export', source, patches));
      final hooks = Directory('${root.path}/hooks')..createSync();
      final hook = File('${hooks.path}/applypatch-msg')
        ..writeAsStringSync(
            '#!/bin/sh\nif grep -q "^Rejected second patch" "\$1"; then exit 1; fi\nexit 0\n');
      expect((await Process.run('chmod', ['+x', hook.path])).exitCode, 0);
      await _git(target, ['config', 'core.hooksPath', hooks.path]);
      final result = await _tool('import', target, patches, ['--reset']);
      expect(result.stdout, contains('Applying: Feature'));
      await failedAtBase(result);
    });

    for (final kind in ['unstaged', 'staged', 'untracked', 'deleted']) {
      test(
          'reset refuses $kind work without creating a backup or changing history',
          () async {
        if (kind == 'untracked')
          _write(target, 'unsaved.txt', 'work\n');
        else if (kind == 'deleted')
          File('${target.path}/base.txt').deleteSync();
        else {
          _write(target, 'base.txt', 'unsaved\n');
          if (kind == 'staged') await _git(target, ['add', 'base.txt']);
        }
        await rejects(error: 'uncommitted changes');
      });
    }

    test(
        'reset refuses a missing upstream ref instead of guessing from a branch name',
        () async {
      await _git(target, ['update-ref', '-d', upstreamHead]);
      await rejects(error: 'without a recorded upstream base');
    });

    test('reset refuses an upstream ref pointing to a blob', () async {
      final blob = await _git(target, ['rev-parse', 'HEAD:base.txt']);
      await _git(target, ['update-ref', upstreamHead, blob]);
      await rejects(error: 'must point to a commit');
    });

    test('reset refuses an upstream ref unrelated to HEAD', () async {
      final tree = await _git(target, ['rev-parse', 'HEAD^{tree}']);
      final unrelated =
          await _git(target, ['commit-tree', tree, '-m', 'Unrelated root']);
      await _git(target, ['update-ref', upstreamHead, unrelated]);
      await rejects(error: 'not an ancestor');
    });

    test('reset refuses an upstream ref that already contains imported patches',
        () async {
      await _git(target, ['update-ref', upstreamHead, 'HEAD']);
      await rejects(error: 'contains imported patch metadata');
    });

    for (final operation in [
      'rebase-apply',
      'rebase-merge',
      'MERGE_HEAD',
      'CHERRY_PICK_HEAD',
      'REVERT_HEAD',
      'sequencer'
    ]) {
      test('refuses an in-progress $operation operation', () async {
        final gitPath = await _git(target, ['rev-parse', '--absolute-git-dir']);
        final path = '$gitPath/$operation';
        if (operation.endsWith('_HEAD'))
          File(path).writeAsStringSync('$assembled\n');
        else
          Directory(path).createSync();
        // Inspect without write-tree or status while artificial operation state exists.
        for (final options in [
          <String>[],
          ['--reset']
        ]) {
          final result = await _tool('import', target, patches, options);
          expect(result.exitCode, isNot(0));
          expect(result.stderr, contains('operation is in progress'));
          expect(await _git(target, ['rev-parse', 'HEAD']), assembled);
          expect(await _git(target, ['rev-parse', upstreamHead]), base);
          expect(await _backups(target), isEmpty);
        }
      });
    }

    for (final invalid in [
      'missing manifest',
      'missing patch',
      'empty collection',
      'malformed diff',
      'missing author',
      'invalid date'
    ]) {
      test('validates $invalid before resetting or saving a backup', () async {
        final manifest = File('${patches.path}/.patches-master');
        final patch = File('${patches.path}/feature.patch');
        if (invalid == 'missing manifest') manifest.deleteSync();
        if (invalid == 'missing patch') patch.deleteSync();
        if (invalid == 'empty collection') patch.writeAsStringSync('');
        if (invalid == 'malformed diff') {
          final mail = _conflictingMail(patch.readAsStringSync());
          patch.writeAsStringSync(
              mail.replaceFirst('@@ -1 +1 @@', '@@ -1,2 +1,2 @@'));
        }
        if (invalid == 'missing author')
          patch.writeAsStringSync(patch
              .readAsStringSync()
              .replaceFirst(RegExp(r'^From: .*\n', multiLine: true), ''));
        if (invalid == 'invalid date')
          patch.writeAsStringSync(patch.readAsStringSync().replaceFirst(
              RegExp(r'^Date: .*\n', multiLine: true), 'Date: invalid date\n'));
        await rejects();
      });
    }

    for (final path in ['feature.txt', 'base.txt']) {
      test(
          'reset protects ignored files overwritten by ${path == 'base.txt' ? 'restoring upstream' : 'reapplying patches'}',
          () async {
        File('${target.path}/$path').deleteSync();
        _write(target, '.gitignore', 'cache/\n$path\n');
        await _commit(target, 'Remove file and ignore local version');
        _write(target, path, 'ignored local work\n');
        await rejects(error: 'Ignored local files');
        expect(File('${target.path}/$path').readAsStringSync(),
            'ignored local work\n');
      });
    }

    test('reset protects ignored files touched by an intermediate patch',
        () async {
      File('${source.path}/feature.txt').deleteSync();
      await _commit(
          source, 'Delete feature\n\nPatch-Filename: delete_feature.patch');
      await _success(await _tool('export', source, patches));
      File('${target.path}/feature.txt').deleteSync();
      _write(target, '.gitignore', 'cache/\nfeature.txt\n');
      await _commit(target, 'Local ignored file');
      _write(target, 'feature.txt', 'ignored intermediate data\n');
      await rejects(error: 'Ignored local files');
    });

    test(
        'reset protects ignored nested repositories during upstream restoration',
        () async {
      File('${target.path}/base.txt').deleteSync();
      _write(target, '.gitignore', 'cache/\nbase.txt/\n');
      await _commit(target, 'Replace upstream file with an ignored directory');
      final nested = Directory('${target.path}/base.txt')..createSync();
      await _git(nested, ['init', '-q']);
      _write(nested, 'data.txt', 'nested repository data\n');
      await rejects(error: 'Ignored local files');
      expect(File('${nested.path}/data.txt').readAsStringSync(),
          'nested repository data\n');
      expect(Directory('${nested.path}/.git').existsSync(), isTrue);
    });

    test('reset works in a linked worktree without changing the other checkout',
        () async {
      final linked = Directory('${root.path}/linked');
      await _git(target, ['worktree', 'add', '--detach', linked.path, 'HEAD']);
      await updateFeature();
      await _success(await _tool('import', linked, patches, ['--reset']));
      expect(File('${linked.path}/feature.txt').readAsStringSync(),
          'updated feature\n');
      expect(File('${target.path}/feature.txt').readAsStringSync(),
          'first feature\n');
      expect(await _git(target, ['rev-parse', 'HEAD']), assembled);
    });
  });
}

void _write(Directory root, String name, String contents) {
  final file = File('${root.path}/$name');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

Future<void> _success(ProcessResult result) async {
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
}

Future<String> _git(Directory root, List<String> args) async {
  final result = await Process.run('git', ['-C', root.path, ...args]);
  expect(result.exitCode, 0, reason: '$args: ${result.stderr}');
  return (result.stdout as String).trim();
}

Future<void> _commit(Directory root, String message) async {
  await _git(root, ['add', '.']);
  await _git(root, ['commit', '-qm', message]);
}

Future<void> _configure(Directory root) async {
  for (final entry in {
    'user.name': 'Nest tests',
    'user.email': 'nest@example.invalid',
    'commit.gpgsign': 'false',
    'core.hooksPath': '/dev/null'
  }.entries) {
    await _git(root, ['config', entry.key, entry.value]);
  }
}

Future<List<String>> _backups(Directory root) async => (await _git(
        root, ['for-each-ref', '--format=%(refname)', 'refs/patches/backups/']))
    .split('\n')
    .where((line) => line.isNotEmpty)
    .toList();
Future<ProcessResult> _tool(
        String operation, Directory repository, Directory patches,
        [List<String> options = const []]) =>
    Process.run(Platform.resolvedExecutable, [
      'run',
      '${Directory.current.path}/bin/git_${operation}_patches.dart',
      '-f',
      repository.path,
      '-p',
      patches.path,
      if (!options.contains('--channel')) ...['--channel', 'master'],
      ...options,
    ]);

String _conflictingMail(String first) =>
    first.substring(0, first.indexOf('diff --git ')) +
    '''diff --git a/base.txt b/base.txt
--- a/base.txt
+++ b/base.txt
@@ -1 +1 @@
-not the base contents
+conflict
''';
