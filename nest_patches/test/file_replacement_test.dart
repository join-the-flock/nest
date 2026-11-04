import 'dart:convert';
import 'dart:io';

import 'package:nest_patches/nest_patches.dart';
import 'package:test/test.dart';

void main() {
  group('Replacement paths >', () {
    for (final path in [
      '',
      '../outside',
      '/absolute',
      '.git/config',
      'a/../b',
      'a//b',
      './file',
      'a\\b',
      'C:/file',
      ' leading',
      'trailing ',
      'tab\tfile',
      'line\nfile',
      'nul\x00file'
    ]) {
      test('rejects ${jsonEncode(path)}', () {
        expect(() => validateReplacementPath(path), throwsFormatException);
      });
    }
  });

  group('File replacements >', () {
    late Directory root, source, collection;
    late String base;
    setUp(() async {
      root = Directory.systemTemp.createTempSync('nest-replacement-tests-');
      source = Directory('${root.path}/source')..createSync();
      collection = Directory('${root.path}/patches')..createSync();
      await _git(source, ['init', '-q']);
      await _configure(source);
      File('${source.path}/README.md')
          .writeAsStringSync('Original upstream README\n');
      File('${source.path}/ordinary.txt')
          .writeAsStringSync('ordinary baseline\n');
      await _commit(source, 'Base');
      base = await _git(source, ['rev-parse', 'HEAD']);
      await _git(source, ['update-ref', upstreamHead, 'HEAD']);
    });
    tearDown(() => root.deleteSync(recursive: true));

    Future<void> author(
        {String contents = '# Our README\n',
        List<String> paths = const ['README.md'],
        bool ordinary = false}) async {
      File('${source.path}/README.md').writeAsStringSync(contents);
      if (ordinary)
        File('${source.path}/ordinary.txt')
            .writeAsStringSync('ordinary change\n');
      await _commit(source, _message(paths));
    }

    Future<Directory> target() async {
      final directory = Directory('${root.path}/target');
      final clone = await Process.run('git',
          ['clone', '--shared', '--no-checkout', source.path, directory.path]);
      expect(clone.exitCode, 0, reason: '${clone.stderr}');
      await _git(directory, ['checkout', '--detach', base]);
      await _configure(directory);
      return directory;
    }

    Future<String> export(
        {Directory? repository,
        Directory? destination,
        List<String> options = const []}) async {
      final output = destination ?? collection;
      await _success(
          await _tool('export', repository ?? source, output, options));
      return File('${output.path}/replacement.patch').readAsStringSync();
    }

    Future<void> roundTrip(Directory directory, String expected) async {
      final output = Directory('${root.path}/again')..createSync();
      expect(
          await export(repository: directory, destination: output), expected);
    }

    test('imports a minimal handwritten replacement without an index header',
        () async {
      File('${collection.path}/replacement.patch')
          .writeAsStringSync(_mail(_replacementDiff()));
      File('${collection.path}/.patches-master')
          .writeAsStringSync('replacement.patch\n');
      final directory = await target();
      await _success(await _tool('import', directory, collection));
      expect(File('${directory.path}/README.md').readAsStringSync(),
          'replacement\n');
      expect(
          await _git(directory, ['log', '-1', '--format=%an']), 'Test Author');
      final output = Directory('${root.path}/again')..createSync();
      final patch = await export(repository: directory, destination: output);
      expect(patch, contains('replace file mode 100644'));
      expect(patch, isNot(contains('Patch-Replace-File:')));
    });

    test('omits unmarked empty commits while retaining marked ones', () async {
      await _git(
          source, ['commit', '--allow-empty', '-qm', 'Unmarked empty commit']);
      await author();
      final patch = await export();
      expect(patch, isNot(contains('Unmarked empty commit')));
      final directory = await target();
      await _success(await _tool('import', directory, collection));
      expect(
          await _git(directory, ['rev-list', '--count', '$base..HEAD']), '1');
    });

    test('preserves whitespace even when Git is configured to fix it',
        () async {
      const image = 'line with trailing spaces  \n';
      await author(contents: image);
      await export();
      final directory = await target();
      await _git(directory, ['config', 'apply.whitespace', 'fix']);
      await _success(await _tool('import', directory, collection));
      expect(File('${directory.path}/README.md').readAsStringSync(), image);
    });

    test(
        'replaces changed upstream, preserves ordinary changes and exports without original patches',
        () async {
      await author(ordinary: true);
      final patch = await export();
      expect(patch, contains('replace file mode 100644'));
      expect(patch, isNot(contains('Original upstream README')));
      expect(patch, isNot(contains('Patch-Replace-File:')));
      final directory = await target();
      File('${directory.path}/README.md')
          .writeAsStringSync('Entirely different upstream\n');
      await _commit(directory, 'Upstream README update');
      final upstream = await _git(directory, ['rev-parse', 'HEAD']);
      await _success(await _tool('import', directory, collection, ['-3']));
      expect(File('${directory.path}/README.md').readAsStringSync(),
          '# Our README\n');
      expect(File('${directory.path}/ordinary.txt').readAsStringSync(),
          'ordinary change\n');
      expect(await _git(directory, ['rev-parse', upstreamHead]), upstream);
      expect(await _git(directory, ['status', '--porcelain']), isEmpty);
      expect(await _git(directory, ['log', '-1', '--format=%B']),
          contains('Patch-Replace-File: README.md'));
      expect(await _git(directory, ['log', '-1', '--format=%an <%ae>%n%aI']),
          await _git(source, ['log', '-1', '--format=%an <%ae>%n%aI']));
      collection.deleteSync(recursive: true);
      await roundTrip(directory, patch);
    });

    test('creates a file deleted upstream', () async {
      await author();
      await export();
      final directory = await target();
      File('${directory.path}/README.md').deleteSync();
      await _commit(directory, 'Remove README');
      await _success(await _tool('import', directory, collection));
      expect(File('${directory.path}/README.md').readAsStringSync(),
          '# Our README\n');
    });

    test('retains intent when replacement already matches upstream', () async {
      await author();
      final patch = await export();
      final directory = await target();
      File('${directory.path}/README.md').writeAsStringSync('# Our README\n');
      await _commit(directory, 'Matching upstream');
      final tree = await _git(directory, ['rev-parse', 'HEAD^{tree}']);
      final head = await _git(directory, ['rev-parse', 'HEAD']);
      await _success(await _tool('import', directory, collection));
      expect(await _git(directory, ['rev-parse', 'HEAD^{tree}']), tree);
      expect(await _git(directory, ['rev-parse', 'HEAD']), isNot(head));
      await roundTrip(directory, patch);
    });

    for (final empty in [false, true]) {
      test('exports unchanged replacement files (empty commit=$empty)',
          () async {
        if (!empty)
          File('${source.path}/ordinary.txt').writeAsStringSync('changed\n');
        await _git(source, ['add', '.']);
        await _git(source, [
          'commit',
          '--allow-empty',
          '-qm',
          _message(['README.md'])
        ]);
        final patch = await export();
        expect(patch, contains('+Original upstream README'));
        final directory = await target();
        await _success(await _tool('import', directory, collection));
        await roundTrip(directory, patch);
      });
    }

    test(
        'round-trips multiple images, binary, CRLF, empty, no newline, modes and quoted paths',
        () async {
      final files = <String, List<int>>{
        'README.md': [],
        'crlf.txt': utf8.encode('one\r\ntwo\r\n'),
        'no-newline.txt': utf8.encode('no final newline'),
        'nested/文 [read me]*.txt': utf8.encode('世界 🐦\n'),
        'protocol-example.txt': utf8
            .encode('Patch-Replace-File: example\nreplace file mode 100644\n'),
        'binary.dat': List.generate(512, (index) => index % 256),
        'script.sh': utf8.encode('#!/bin/sh\n'),
      };
      for (final entry in files.entries) {
        final file = File('${source.path}/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(entry.value);
      }
      Link('${source.path}/link').createSync('README.md');
      expect(
          (await Process.run('chmod', ['+x', '${source.path}/script.sh']))
              .exitCode,
          0);
      await _commit(source, _message([...files.keys, 'link']));
      final patch = await export();
      expect(patch, contains('replace file mode 100755'));
      expect(patch, contains('replace file mode 120000'));
      expect(patch, contains('GIT binary patch'));
      final directory = await target();
      await _success(await _tool('import', directory, collection, ['-3']));
      expect(await _git(directory, ['rev-parse', 'HEAD^{tree}']),
          await _git(source, ['rev-parse', 'HEAD^{tree}']));
      for (final entry in files.entries) {
        expect(File('${directory.path}/${entry.key}').readAsBytesSync(),
            entry.value);
      }
      expect(Link('${directory.path}/link').targetSync(), 'README.md');
      await roundTrip(directory, patch);
    });

    test('applies successive replacements in a multi-commit patch', () async {
      await author(contents: 'first\n');
      await author(contents: 'second\n');
      final patch = await export();
      final directory = await target();
      File('${directory.path}/README.md').writeAsStringSync('new upstream\n');
      await _commit(directory, 'Upstream');
      await _success(await _tool('import', directory, collection));
      expect(
          File('${directory.path}/README.md').readAsStringSync(), 'second\n');
      await roundTrip(directory, patch);
    });

    for (final first in [false, true]) {
      test(
          'combines ordinary and replacement commits (replacement first=$first)',
          () async {
        Future<void> ordinary() async {
          File('${source.path}/README.md').writeAsStringSync('ordinary edit\n');
          await _commit(
              source, 'Ordinary edit\n\nPatch-Filename: replacement.patch');
        }

        if (first) {
          await author();
          await ordinary();
        } else {
          await ordinary();
          await author();
        }
        final patch = await export();
        final directory = await target();
        await _success(await _tool('import', directory, collection));
        expect(await _git(directory, ['rev-parse', 'HEAD^{tree}']),
            await _git(source, ['rev-parse', 'HEAD^{tree}']));
        await roundTrip(directory, patch);
      });
    }

    test('preserves conflicts in ordinary files without changing the checkout',
        () async {
      await author(ordinary: true);
      await export();
      final directory = await target();
      File('${directory.path}/ordinary.txt')
          .writeAsStringSync('upstream conflict\n');
      await _commit(directory, 'Upstream');
      final head = await _git(directory, ['rev-parse', 'HEAD']);
      expect((await _tool('import', directory, collection, ['-3'])).exitCode,
          isNot(0));
      expect(await _git(directory, ['rev-parse', 'HEAD']), head);
      expect(await _git(directory, ['status', '--porcelain']), isEmpty);
      expect(File('${directory.path}/README.md').readAsStringSync(),
          'Original upstream README\n');
    });

    test('does not overwrite local uncommitted edits', () async {
      await author();
      await export();
      final directory = await target();
      File('${directory.path}/README.md').writeAsStringSync('local work\n');
      expect((await _tool('import', directory, collection)).exitCode, isNot(0));
      expect(await _git(directory, ['rev-parse', 'HEAD']), base);
      expect(File('${directory.path}/README.md').readAsStringSync(),
          'local work\n');
    });

    test('cannot traverse a symlink directory', () async {
      File('${source.path}/nested/file.txt').parent.createSync();
      File('${source.path}/nested/file.txt').writeAsStringSync('new\n');
      await author(paths: ['nested/file.txt']);
      await export();
      final directory = await target();
      final outside = Directory('${root.path}/outside')..createSync();
      File('${outside.path}/file.txt').writeAsStringSync('untouched\n');
      Link('${directory.path}/nested').createSync(outside.path);
      await _commit(directory, 'Symlink ancestor');
      expect((await _tool('import', directory, collection)).exitCode, isNot(0));
      expect(
          File('${outside.path}/file.txt').readAsStringSync(), 'untouched\n');
    });

    test('replaces a symlink itself without writing through it', () async {
      await author();
      final patch = await export();
      final directory = await target();
      final outside = File('${root.path}/outside.txt')
        ..writeAsStringSync('untouched\n');
      File('${directory.path}/README.md').deleteSync();
      Link('${directory.path}/README.md').createSync(outside.path);
      await _commit(directory, 'Upstream symlink');
      await _success(await _tool('import', directory, collection, ['-3']));
      expect(
          FileSystemEntity.isLinkSync('${directory.path}/README.md'), isFalse);
      expect(File('${directory.path}/README.md').readAsStringSync(),
          '# Our README\n');
      expect(outside.readAsStringSync(), 'untouched\n');
      await roundTrip(directory, patch);
    });

    test('exports a renamed file as a replacement and retains the old deletion',
        () async {
      Directory('${source.path}/docs').createSync();
      await _git(source, ['mv', 'README.md', 'docs/README.md']);
      await _commit(source, _message(['docs/README.md']));
      final patch = await export();
      expect(patch, contains('deleted file mode 100644'));
      expect(patch, contains('replace file mode 100644'));
      final directory = await target();
      await _success(await _tool('import', directory, collection));
      expect(File('${directory.path}/README.md').existsSync(), isFalse);
      expect(File('${directory.path}/docs/README.md').readAsStringSync(),
          'Original upstream README\n');
      await roundTrip(directory, patch);
    });

    test('dry run reports changed replacement images without writing',
        () async {
      await author();
      final patch = await export();
      await export(options: ['--dry-run']);
      File('${source.path}/README.md').writeAsStringSync('amended image\n');
      await _git(source, ['add', '.']);
      await _git(source, ['commit', '--amend', '--no-edit', '-q']);
      final result = await _tool('export', source, collection, ['--dry-run']);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Export would change:'));
      expect(File('${collection.path}/replacement.patch').readAsStringSync(),
          patch);
      expect(await export(), contains('+amended image'));
    });

    final valid = _replacementDiff();
    final invalid = <String, String>{
      'unsupported mode': valid.replaceFirst('100644', '160000'),
      'duplicate header': valid.replaceFirst('replace file mode 100644',
          'replace file mode 100644\nreplace file mode 100644'),
      'conflicting addition': valid.replaceFirst('replace file mode 100644',
          'replace file mode 100644\nnew file mode 100644'),
      'conflicting rename': valid.replaceFirst('replace file mode 100644',
          'replace file mode 100644\nrename from other.txt'),
      'old blob': valid.replaceFirst('replace file mode 100644',
          'replace file mode 100644\nindex 1234567..abcdef0'),
      'missing hunk': valid.replaceFirst('@@ -0,0 +1 @@\n', ''),
      'old file': valid.replaceFirst('--- /dev/null', '--- a/README.md'),
      'incomplete image': valid
          .replaceFirst('@@ -0,0 +1 @@', '@@ -1 +1 @@')
          .replaceFirst('+replacement', ' context\n+replacement'),
      'truncated image': valid.replaceFirst('@@ -0,0 +1 @@', '@@ -0,0 +2 @@'),
      'duplicate destination': '$valid$valid',
      'ordinary diff for replacement destination':
          '$valid${valid.replaceFirst('replace file mode', 'new file mode')}',
      'malformed header': valid.replaceFirst(
          'replace file mode 100644', 'replace file nonsense'),
      'unsafe destination': _replacementDiff(path: '../outside'),
    };
    for (final entry in invalid.entries) {
      test('rejects ${entry.key} before changing checkout or upstream ref',
          () async {
        File('${collection.path}/replacement.patch')
            .writeAsStringSync(_mail(entry.value));
        File('${collection.path}/.patches-master')
            .writeAsStringSync('replacement.patch\n');
        final directory = await target();
        final index = await _git(directory, ['write-tree']);
        expect(
            (await _tool('import', directory, collection)).exitCode, isNot(0));
        expect(await _git(directory, ['rev-parse', 'HEAD']), base);
        expect(await _git(directory, ['write-tree']), index);
        expect(await _git(directory, ['status', '--porcelain']), isEmpty);
        expect(
            (await Process.run('git', [
              '-C',
              directory.path,
              'rev-parse',
              '--verify',
              upstreamHead
            ]))
                .exitCode,
            isNot(0));
      });
    }
    test('rejects reserved metadata in incoming descriptions', () async {
      final mail = _mail(valid).replaceFirst(
          '\n\n---\n', '\n\nPatch-Replace-File: README.md\n\n---\n');
      File('${collection.path}/replacement.patch').writeAsStringSync(mail);
      File('${collection.path}/.patches-master')
          .writeAsStringSync('replacement.patch\n');
      final directory = await target();
      final result = await _tool('import', directory, collection);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('reserved import metadata'));
      expect(await _git(directory, ['rev-parse', 'HEAD']), base);
    });

    for (final paths in [
      ['README.md', 'README.md'],
      ['missing.txt'],
      ['.git/config'],
      ['..'],
      ['nested']
    ]) {
      test('rejects invalid export declaration $paths without writing',
          () async {
        Directory('${source.path}/nested').createSync();
        File('${source.path}/nested/file').writeAsStringSync('nested\n');
        await author(paths: paths);
        File('${collection.path}/keep.txt').writeAsStringSync('untouched');
        expect((await _tool('export', source, collection)).exitCode, isNot(0));
        expect(
            collection.listSync().map((entry) => entry.uri.pathSegments.last),
            ['keep.txt']);
        expect(File('${collection.path}/keep.txt').readAsStringSync(),
            'untouched');
      });
    }
  });
}

String _message(List<String> paths) =>
    'Replace documentation\n\nExplanation.\n\n'
    '${paths.map((path) => 'Patch-Replace-File: $path\n').join()}'
    'Patch-Filename: replacement.patch';
String _replacementDiff({String path = 'README.md'}) =>
    '''diff --git a/$path b/$path
replace file mode 100644
--- /dev/null
+++ b/$path
@@ -0,0 +1 @@
+replacement
''';
String _mail(String diff) => '''From ${'0' * 40} Mon Sep 17 00:00:00 2001
From: Test Author <test@example.invalid>
Date: Wed, 4 Nov 2026 12:00:00 -0500
Subject: [PATCH] Replace README

---
$diff''';
Future<ProcessResult> _tool(
        String operation, Directory repository, Directory collection,
        [List<String> options = const []]) =>
    Process.run(Platform.resolvedExecutable, [
      'run',
      '${Directory.current.path}/bin/git_${operation}_patches.dart',
      '-f',
      repository.path,
      '-p',
      collection.path,
      '--channel',
      'master',
      ...options
    ]);
Future<void> _success(ProcessResult result) async {
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
}

Future<String> _git(Directory repository, List<String> args) async {
  final result = await Process.run('git', ['-C', repository.path, ...args]);
  expect(result.exitCode, 0, reason: '$args: ${result.stderr}');
  return (result.stdout as String).trim();
}

Future<void> _commit(Directory repository, String message) async {
  await _git(repository, ['add', '.']);
  await _git(repository, ['commit', '-qm', message]);
}

Future<void> _configure(Directory repository) async {
  for (final setting in {
    'user.name': 'Nest tests',
    'user.email': 'nest@example.invalid',
    'commit.gpgsign': 'false',
    'core.hooksPath': '/dev/null',
    'core.autocrlf': 'false'
  }.entries) {
    await _git(repository, ['config', setting.key, setting.value]);
  }
}
