import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('Channel patch tools >', () {
    late Directory root;
    late Directory source;
    late Directory collection;
    late String base;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('nest patch tools-');
      source = Directory('${root.path}/source')..createSync();
      collection = Directory('${root.path}/patches')..createSync();
      await _initialize(source);
      File('${source.path}/base.txt').writeAsStringSync('base\n');
      await _commit(source, 'Base');
      base = await _git(source, ['rev-parse', 'HEAD']);
      await _git(source, ['update-ref', 'refs/patches/upstream-head', base]);
      File('${source.path}/feature.txt').writeAsStringSync('feature\n');
      await _commit(source, 'Add feature\n\nPatch-Filename: feature.patch');
      await _expectSuccess(
          await _export(source, collection, ['--channel', 'master']));
      for (final channel in ['beta', 'stable']) {
        File('${collection.path}/.patches-$channel')
            .writeAsStringSync('feature.patch\n');
      }
    });

    tearDown(() => root.deleteSync(recursive: true));

    group('Patch contents and Git behavior >', () {
      test('round-trips edits, deletes, renames, modes, and symlinks',
          () async {
        await _git(source, ['reset', '--hard', base]);
        File('${source.path}/delete.txt').writeAsStringSync('delete me\n');
        File('${source.path}/before.txt').writeAsStringSync('rename me\n');
        File('${source.path}/script.sh').writeAsStringSync('#!/bin/sh\n');
        await _commit(source, 'Prepare file operations');
        final operationBase = await _git(source, ['rev-parse', 'HEAD']);
        await _git(
            source, ['update-ref', 'refs/patches/upstream-head', 'HEAD']);
        File('${source.path}/base.txt').writeAsStringSync('modified\n');
        File('${source.path}/delete.txt').deleteSync();
        await _git(source, ['mv', 'before.txt', 'after.txt']);
        await _git(source, ['update-index', '--chmod=+x', 'script.sh']);
        // Commit the index mode directly: git add would reset it from disk.
        await Process.run('chmod', ['+x', '${source.path}/script.sh']);
        Link('${source.path}/link.txt').createSync('after.txt');
        await _commit(
            source, 'File operations\n\nPatch-Filename: operations.patch');
        await _expectSuccess(
            await _export(source, collection, ['--channel', 'master']));
        final patch =
            File('${collection.path}/operations.patch').readAsStringSync();
        expect(patch, contains('deleted file mode'));
        expect(patch, contains('rename from before.txt'));
        expect(patch, contains('new mode 100755'));
        expect(patch, contains('new file mode 120000'));
        final target = await _baseCheckout(root, source, operationBase);
        await _expectSuccess(
            await _import(target, collection, ['--channel', 'master']));
        expect(await _git(target, ['rev-parse', 'HEAD^{tree}']),
            await _git(source, ['rev-parse', 'HEAD^{tree}']));
        expect(File('${target.path}/delete.txt').existsSync(), isFalse);
        expect(Link('${target.path}/link.txt').targetSync(), 'after.txt');
        await _expectRoundTrip(target, collection, root, 'operations.patch');
      });

      for (final entry in <String, List<int>>{
        'crlf': utf8.encode('first\r\nsecond\r\n'),
        'no_final_newline': utf8.encode('no final newline'),
        'unicode': utf8.encode('Hello, 世界 🐦\n'),
        'binary': List.generate(512, (index) => index % 256),
        'empty': [],
      }.entries) {
        test('round-trips ${entry.key} content without byte changes', () async {
          File('${source.path}/space ${entry.key}.txt')
              .writeAsBytesSync(entry.value);
          await _commit(
              source, 'Add ${entry.key}\n\nPatch-Filename: contents.patch');
          await _expectSuccess(await _export(source, collection,
              ['--channel', 'master', '--grep', 'Add ${entry.key}']));
          final target = await _baseCheckout(root, source, base);
          await _expectSuccess(
              await _import(target, collection, ['--channel', 'master']));
          expect(
              File('${target.path}/space ${entry.key}.txt').readAsBytesSync(),
              entry.value);
          await _expectRoundTrip(target, collection, root, 'contents.patch');
        });
      }

      test('preserves author, date, subject, body and strips internal metadata',
          () async {
        const message =
            'A descriptive subject\n\nExplanation.\n\nSigned-off-by: Tester <test@example.invalid>';
        await _git(source, [
          'commit',
          '--amend',
          '--author',
          'Original Author <original@example.invalid>',
          '--date',
          '2020-01-02T03:04:05+0200',
          '-qm',
          message
        ]);
        await _expectSuccess(
            await _export(source, collection, ['--channel', 'master']));
        const name = 'a_descriptive_subject.patch';
        final target = await _baseCheckout(root, source, base);
        await _expectSuccess(
            await _import(target, collection, ['--channel', 'master']));
        expect(await _git(target, ['log', '-1', '--format=%an <%ae>%n%aI']),
            'Original Author <original@example.invalid>\n2020-01-02T03:04:05+02:00');
        final body = await _git(target, ['log', '-1', '--format=%B']);
        expect(body, contains(message));
        expect(body, contains('Patch-Filename: $name'));
        final roundTrip =
            await _expectRoundTrip(target, collection, root, name);
        expect(roundTrip, isNot(contains('Patch-Dir:')));
        expect(roundTrip, isNot(contains('Patch-Filename:')));
      });

      test('applies dependent patch files in manifest order', () async {
        File('${source.path}/feature.txt')
            .writeAsStringSync('second version\n');
        await _commit(source, 'Update feature\n\nPatch-Filename: update.patch');
        await _expectSuccess(
            await _export(source, collection, ['--channel', 'master']));
        final target = await _baseCheckout(root, source, base);
        await _expectSuccess(
            await _import(target, collection, ['--channel', 'master']));
        expect(File('${target.path}/feature.txt').readAsStringSync(),
            'second version\n');
        expect(
            await _git(
                target, ['log', '--reverse', '--format=%s', '$base..HEAD']),
            'Add feature\nUpdate feature');
      });

      test(
          'uses explicit ranges and falls back to tags without an upstream ref',
          () async {
        await _git(source, ['tag', 'baseline', base]);
        await _git(source, ['update-ref', '-d', 'refs/patches/upstream-head']);
        await _expectSuccess(await _export(
            source, collection, ['--channel', 'master', '--dry-run']));
        await _expectSuccess(await _export(source, collection,
            ['--channel', 'master', '$base..HEAD', '--dry-run']));
      });

      for (final threeway in [false, true]) {
        test(
            'reports a conflict and leaves git am recoverable (3way=$threeway)',
            () async {
          await _git(source, ['reset', '--hard', base]);
          File('${source.path}/base.txt').writeAsStringSync('patch version\n');
          await _commit(source, 'Edit base\n\nPatch-Filename: edit.patch');
          await _expectSuccess(
              await _export(source, collection, ['--channel', 'master']));
          final target = await _baseCheckout(root, source, base);
          File('${target.path}/base.txt')
              .writeAsStringSync('upstream version\n');
          await _commit(target, 'Upstream edit');
          final upstream = await _git(target, ['rev-parse', 'HEAD']);
          final result = await _import(
              target, collection, ['--channel', 'master', if (threeway) '-3']);
          expect(result.exitCode, isNot(0));
          expect(
              await _git(target, ['rev-parse', 'refs/patches/upstream-head']),
              upstream);
          await _git(target, ['am', '--abort']);
          expect(await _git(target, ['rev-parse', 'HEAD']), upstream);
          expect(await _git(target, ['status', '--porcelain']), isEmpty);
        });
      }

      test('3way merges when changed context prevents direct application',
          () async {
        await _git(source, ['reset', '--hard', base]);
        File('${source.path}/base.txt')
            .writeAsStringSync('one\ntwo\nthree\nfour\nfive\n');
        await _commit(source, 'Prepare merge');
        final mergeBase = await _git(source, ['rev-parse', 'HEAD']);
        await _git(
            source, ['update-ref', 'refs/patches/upstream-head', 'HEAD']);
        File('${source.path}/base.txt')
            .writeAsStringSync('ONE\ntwo\nthree\nfour\nfive\n');
        await _commit(
            source, 'Change first line\n\nPatch-Filename: merge.patch');
        await _expectSuccess(
            await _export(source, collection, ['--channel', 'master']));
        final target = await _baseCheckout(root, source, mergeBase);
        File('${target.path}/base.txt')
            .writeAsStringSync('one\ntwo\nTHREE\nfour\nfive\n');
        await _commit(target, 'Change context');
        final direct =
            await _import(target, collection, ['--channel', 'master']);
        expect(direct.exitCode, isNot(0));
        await _git(target, ['am', '--abort']);
        await _expectSuccess(
            await _import(target, collection, ['--channel', 'master', '-3']));
        expect(File('${target.path}/base.txt').readAsStringSync(),
            'ONE\ntwo\nTHREE\nfour\nfive\n');
      });

      test('rejects missing and malformed patch data', () async {
        final target = await _baseCheckout(root, source, base);
        File('${collection.path}/.patches-master')
            .writeAsStringSync('missing.patch\n');
        expect(
            (await _import(target, collection, ['--channel', 'master']))
                .exitCode,
            isNot(0));
        expect(await _git(target, ['rev-parse', 'HEAD']), base);
        File('${collection.path}/missing.patch')
            .writeAsStringSync('not a patch\n');
        expect(
            (await _import(target, collection, ['--channel', 'master']))
                .exitCode,
            isNot(0));
        expect(await _git(target, ['rev-parse', 'HEAD']), base);
      });

      test('preserves unrelated local work during import', () async {
        final target = await _baseCheckout(root, source, base);
        File('${target.path}/base.txt').writeAsStringSync('local changes\n');
        File('${target.path}/untracked.txt').writeAsStringSync('keep\n');
        await _expectSuccess(
            await _import(target, collection, ['--channel', 'master']));
        expect(File('${target.path}/base.txt').readAsStringSync(),
            'local changes\n');
        expect(
            File('${target.path}/untracked.txt').readAsStringSync(), 'keep\n');
      });
    });

    group('Manifest validation >', () {
      for (final contents in [
        '',
        '\n',
        'feature.patch\nfeature.patch\n',
        'feature.patch\nfeature_2026-09-08.patch\n',
        ' feature.patch\n',
        'wrong.txt\n',
        '.patch\n',
        'feature_2026-02-29.patch\n'
      ]) {
        test(
            'rejects invalid manifest ${jsonEncode(contents)} without mutation',
            () async {
          File('${collection.path}/.patches-master')
              .writeAsStringSync(contents);
          final before = _snapshot(collection);
          final target = await _baseCheckout(root, source, base);
          expect(
              (await _import(target, collection, ['--channel', 'master']))
                  .exitCode,
              isNot(0));
          expect(await _git(target, ['rev-parse', 'HEAD']), base);
          expect(_snapshot(collection), before);
        });
      }
      test('rejects symlink manifests on import and export', () async {
        File('${collection.path}/.patches-master').deleteSync();
        Link('${collection.path}/.patches-master').createSync('.patches-beta');
        final target = await _baseCheckout(root, source, base);
        for (final result in [
          await _import(target, collection, ['--channel', 'master']),
          await _export(source, collection, ['--channel', 'master'])
        ]) {
          expect(result.exitCode, isNot(0));
          expect(result.stderr, contains('regular file'));
        }
      });
    });

    group('Import selection >', () {
      test('imports the selected dated variant and preserves the collection',
          () async {
        final adapted = File('${collection.path}/feature_2026-09-08.patch')
          ..writeAsBytesSync(
              File('${collection.path}/feature.patch').readAsBytesSync());
        File('${collection.path}/.patches-stable')
            .writeAsStringSync('feature_2026-09-08.patch\n');
        final before = _snapshot(collection);
        final target = await _baseCheckout(root, source, base);
        await _expectSuccess(
            await _import(target, collection, ['--channel', 'stable', '-3']));
        expect(
            File('${target.path}/feature.txt').readAsStringSync(), 'feature\n');
        expect(await _git(target, ['log', '-1', '--format=%B']),
            contains('Patch-Filename: feature_2026-09-08.patch'));
        expect(await _git(target, ['rev-parse', 'refs/patches/upstream-head']),
            base);
        expect(await _git(target, ['status', '--porcelain']), isEmpty);
        expect(_snapshot(collection), before);
        expect(adapted.existsSync(), isTrue);
      });

      test('accepts an explicit channel manifest', () async {
        final target = await _baseCheckout(root, source, base);
        await _expectSuccess(
            await _import(target, collection, ['--manifest', '.patches-beta']));
        expect(File('${target.path}/feature.txt').existsSync(), isTrue);
      });

      test('requires selection before changing the target repository',
          () async {
        final target = await _baseCheckout(root, source, base);
        final result = await _import(target, collection);
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('Select a channel'));
        expect(await _git(target, ['rev-parse', 'HEAD']), base);
        expect(
            (await Process.run('git', [
              '-C',
              target.path,
              'rev-parse',
              '--verify',
              'refs/patches/upstream-head'
            ]))
                .exitCode,
            isNot(0));
      });

      test('rejects a missing manifest before changing the target repository',
          () async {
        File('${collection.path}/.patches-stable').deleteSync();
        final target = await _baseCheckout(root, source, base);
        final result =
            await _import(target, collection, ['--channel', 'stable']);
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('.patches-stable'));
        expect(await _git(target, ['rev-parse', 'HEAD']), base);
      });

      test('uses the legacy manifest by default for legacy collections',
          () async {
        _makeLegacy(collection);
        final target = await _baseCheckout(root, source, base);
        await _expectSuccess(await _import(target, collection));
        expect(File('${target.path}/feature.txt').existsSync(), isTrue);
      });

      test('rejects unsafe filenames and symbolic link patches', () async {
        final target = await _baseCheckout(root, source, base);
        final manifest = File('${collection.path}/.patches-stable');
        manifest.writeAsStringSync('../outside.patch\n');
        expect(
            (await _import(target, collection, ['--channel', 'stable']))
                .exitCode,
            isNot(0));
        manifest.writeAsStringSync('linked.patch\n');
        Link('${collection.path}/linked.patch')
            .createSync('${collection.path}/feature.patch');
        final result =
            await _import(target, collection, ['--channel', 'stable']);
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('symlinks'));
        expect(await _git(target, ['rev-parse', 'HEAD']), base);
      });
    });

    group('Export isolation >', () {
      test('requires a channel selection and leaves the collection unchanged',
          () async {
        final before = _snapshot(collection);
        final result = await _export(source, collection);
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('Select a channel'));
        expect(_snapshot(collection), before);
      });

      test('preserves other manifests, their patches, and unlisted files',
          () async {
        final contents =
            File('${collection.path}/feature.patch').readAsBytesSync();
        File('${collection.path}/stable_only.patch').writeAsBytesSync(contents);
        File('${collection.path}/.patches-stable')
            .writeAsStringSync('stable_only.patch\n');
        File('${collection.path}/removed.patch').writeAsBytesSync(contents);
        File('${collection.path}/.patches-master')
            .writeAsStringSync('feature.patch\nremoved.patch\n');
        File('${collection.path}/unlisted.patch').writeAsBytesSync(contents);
        final before = _snapshot(collection);
        await _expectSuccess(
            await _export(source, collection, ['--channel', 'master']));
        expect(File('${collection.path}/removed.patch').existsSync(), isFalse);
        final after = _snapshot(collection);
        for (final name in [
          '.patches-beta',
          '.patches-stable',
          'stable_only.patch',
          'unlisted.patch',
          'feature.patch'
        ]) {
          expect(after[name], before[name], reason: name);
        }
        expect(File('${collection.path}/.patches-master').readAsStringSync(),
            'feature.patch\n');
        expect(File('${collection.path}/.patches').existsSync(), isFalse);
      });

      test('retains a removed patch still referenced by another channel',
          () async {
        File('${source.path}/feature.txt').writeAsStringSync('feature\n');
        await _git(source, [
          'commit',
          '--amend',
          '-qm',
          'Add feature\n\nPatch-Filename: replacement.patch'
        ]);
        await _expectSuccess(
            await _export(source, collection, ['--channel', 'master']));
        expect(File('${collection.path}/feature.patch').existsSync(), isTrue);
        expect(
            File('${collection.path}/replacement.patch').existsSync(), isTrue);
        expect(File('${collection.path}/.patches-master').readAsStringSync(),
            'replacement.patch\n');
        expect(File('${collection.path}/.patches-stable').readAsStringSync(),
            'feature.patch\n');
      });

      test(
          'rejects changed shared contents before writing any collection files',
          () async {
        await _changeFeature(source);
        final before = _snapshot(collection);
        final result =
            await _export(source, collection, ['--channel', 'master']);
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('--update-shared'));
        expect(_snapshot(collection), before);
      });

      test('updates shared contents when explicitly requested', () async {
        await _changeFeature(source);
        final before = _snapshot(collection);
        await _expectSuccess(await _export(
            source, collection, ['--channel', 'master', '--update-shared']));
        final after = _snapshot(collection);
        expect(after['feature.patch'], isNot(before['feature.patch']));
        for (final channel in ['master', 'beta', 'stable']) {
          expect(after['.patches-$channel'], before['.patches-$channel']);
        }
      });

      test('preserves dated filenames on repeated exports', () async {
        await _git(source, [
          'commit',
          '--amend',
          '-qm',
          'Add feature\n\nPatch-Filename: feature_2026-09-08.patch'
        ]);
        await _expectSuccess(
            await _export(source, collection, ['--channel', 'master']));
        final before = _snapshot(collection);
        await _expectSuccess(
            await _export(source, collection, ['--channel', 'master']));
        expect(_snapshot(collection), before);
        expect(File('${collection.path}/.patches-master').readAsStringSync(),
            'feature_2026-09-08.patch\n');
        expect(File('${collection.path}/feature.patch').existsSync(), isTrue);
      });

      test('supports legacy export without deleting unlisted files', () async {
        _makeLegacy(collection);
        File('${collection.path}/unlisted.patch').writeAsStringSync('keep me');
        await _expectSuccess(await _export(source, collection));
        expect(File('${collection.path}/unlisted.patch').readAsStringSync(),
            'keep me');
        expect(File('${collection.path}/.patches').readAsStringSync(),
            'feature.patch\n');
      });

      test(
          'rejects invalid dates or paths in exported filenames before writing',
          () async {
        for (final name in ['../outside.patch', 'feature_2026-02-29.patch']) {
          await _git(source, [
            'commit',
            '--amend',
            '-qm',
            'Add feature\n\nPatch-Filename: $name'
          ]);
          final before = _snapshot(collection);
          expect(
              (await _export(source, collection, ['--channel', 'master']))
                  .exitCode,
              isNot(0));
          expect(_snapshot(collection), before);
        }
        expect(File('${root.path}/outside.patch').existsSync(), isFalse);
      });

      test('rejects two variants of a change in one exported collection',
          () async {
        File('${source.path}/extra.txt').writeAsStringSync('extra\n');
        await _commit(source,
            'Adapt feature\n\nPatch-Filename: feature_2026-09-08.patch');
        final before = _snapshot(collection);
        final result =
            await _export(source, collection, ['--channel', 'master']);
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('multiple variants'));
        expect(_snapshot(collection), before);
      });

      test('rejects exporting an empty collection without deleting files',
          () async {
        await _git(
            source, ['update-ref', 'refs/patches/upstream-head', 'HEAD']);
        final before = _snapshot(collection);
        final result =
            await _export(source, collection, ['--channel', 'master']);
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('empty collection'));
        expect(_snapshot(collection), before);
      });
    });

    group('Filtered exports and review >', () {
      test('retains unselected patches when exporting a matching addition',
          () async {
        File('${source.path}/extra.txt').writeAsStringSync('extra\n');
        await _commit(source, 'Add extra\n\nPatch-Filename: extra.patch');
        final before = _snapshot(collection);
        await _expectSuccess(await _export(source, collection,
            ['--channel', 'master', '--grep', 'Add extra']));
        expect(File('${collection.path}/.patches-master').readAsStringSync(),
            'feature.patch\nextra.patch\n');
        expect(_snapshot(collection)['feature.patch'], before['feature.patch']);
      });

      test('leaves every file unchanged when the filter matches no commits',
          () async {
        final before = _snapshot(collection);
        await _expectSuccess(await _export(source, collection,
            ['--channel', 'master', '--grep', 'no such change']));
        expect(_snapshot(collection), before);
      });

      test('reports pending changes in dry runs and writes nothing', () async {
        File('${source.path}/extra.txt').writeAsStringSync('extra\n');
        await _commit(source, 'Add extra\n\nPatch-Filename: extra.patch');
        final before = _snapshot(collection);
        final result = await _export(
            source, collection, ['--channel', 'master', '--dry-run']);
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('Export would change:'));
        expect(_snapshot(collection), before);
      });

      test('succeeds in dry runs when the collection is current', () async {
        final before = _snapshot(collection);
        await _expectSuccess(await _export(
            source, collection, ['--channel', 'master', '--dry-run']));
        expect(_snapshot(collection), before);
      });
    });

    group('Multi-commit patch files >', () {
      test('exports one manifest entry and imports all commits in order',
          () async {
        File('${source.path}/second.txt').writeAsStringSync('second\n');
        await _commit(
            source, 'Second feature commit\n\nPatch-Filename: feature.patch');
        await _expectSuccess(await _export(
            source, collection, ['--channel', 'master', '--update-shared']));
        expect(File('${collection.path}/.patches-master').readAsStringSync(),
            'feature.patch\n');
        final target = await _baseCheckout(root, source, base);
        await _expectSuccess(
            await _import(target, collection, ['--channel', 'master']));
        expect(await _git(target, ['rev-list', '--count', '$base..HEAD']), '2');
        expect(
            File('${target.path}/second.txt').readAsStringSync(), 'second\n');
        final roundTrip = Directory('${root.path}/round-trip')..createSync();
        await _expectSuccess(
            await _export(target, roundTrip, ['--channel', 'master']));
        expect(File('${roundTrip.path}/.patches-master').readAsStringSync(),
            'feature.patch\n');
        expect(File('${roundTrip.path}/feature.patch').readAsBytesSync(),
            File('${collection.path}/feature.patch').readAsBytesSync());
      });

      test(
          'exports the whole file when a filter matches only one of its commits',
          () async {
        File('${source.path}/second.txt').writeAsStringSync('second\n');
        await _commit(
            source, 'Second feature commit\n\nPatch-Filename: feature.patch');
        await _expectSuccess(await _export(source, collection, [
          '--channel',
          'master',
          '--grep',
          'Second feature',
          '--update-shared'
        ]));
        final target = await _baseCheckout(root, source, base);
        await _expectSuccess(
            await _import(target, collection, ['--channel', 'master']));
        expect(await _git(target, ['rev-list', '--count', '$base..HEAD']), '2');
      });

      test('rejects nonconsecutive commits with one filename before writing',
          () async {
        File('${source.path}/middle.txt').writeAsStringSync('middle\n');
        await _commit(source, 'Middle\n\nPatch-Filename: middle.patch');
        File('${source.path}/last.txt').writeAsStringSync('last\n');
        await _commit(source, 'Last\n\nPatch-Filename: feature.patch');
        final before = _snapshot(collection);
        final result = await _export(
            source, collection, ['--channel', 'master', '--update-shared']);
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('Nonconsecutive'));
        expect(_snapshot(collection), before);
      });
    });
  });
}

Future<void> _initialize(Directory repository) async {
  await _git(repository, ['init', '-q']);
  await _git(repository, ['config', 'user.name', 'Nest tests']);
  await _git(repository, ['config', 'user.email', 'nest@example.invalid']);
  await _git(repository, ['config', 'commit.gpgsign', 'false']);
  await _git(repository, ['config', 'core.hooksPath', '/dev/null']);
}

Future<String> _commit(Directory repository, String message) async {
  await _git(repository, ['add', '.']);
  return _git(repository, ['commit', '-qm', message]);
}

Future<String> _git(Directory repository, List<String> arguments) async {
  final result =
      await Process.run('git', ['-C', repository.path, ...arguments]);
  expect(result.exitCode, 0,
      reason: '${arguments.join(' ')}: ${result.stderr}');
  return (result.stdout as String).trim();
}

Future<void> _expectSuccess(ProcessResult result) async {
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
}

Future<ProcessResult> _export(Directory source, Directory collection,
        [List<String> arguments = const []]) =>
    _runTool('git-export-patches', source, collection, arguments);

Future<ProcessResult> _import(Directory target, Directory collection,
        [List<String> arguments = const []]) =>
    _runTool('git-import-patches', target, collection, arguments);

Future<ProcessResult> _runTool(String name, Directory repository,
    Directory collection, List<String> arguments) {
  final entryPoint = name.replaceAll('-', '_');
  return Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        '${Directory.current.path}/bin/$entryPoint.dart',
        '-f',
        repository.path,
        '-p',
        collection.path,
        ...arguments
      ],
      workingDirectory: collection.parent.path);
}

Map<String, String> _snapshot(Directory directory) => {
      for (final file in directory.listSync().whereType<File>())
        file.path.substring(directory.path.length + 1):
            base64Encode(file.readAsBytesSync()),
    };

Future<Directory> _baseCheckout(
    Directory root, Directory source, String base) async {
  final target = Directory('${root.path}/target');
  final result = await Process.run(
      'git', ['clone', '--shared', '--no-checkout', source.path, target.path]);
  expect(result.exitCode, 0, reason: result.stderr as String);
  await _git(target, ['checkout', '--detach', base]);
  await _initialize(target);
  // Private assembly refs are not normally published or cloned.
  await _git(target, ['update-ref', '-d', 'refs/patches/upstream-head']);
  return target;
}

void _makeLegacy(Directory collection) {
  for (final channel in ['master', 'beta', 'stable']) {
    File('${collection.path}/.patches-$channel').deleteSync();
  }
  File('${collection.path}/.patches').writeAsStringSync('feature.patch\n');
}

Future<void> _changeFeature(Directory source) async {
  File('${source.path}/feature.txt').writeAsStringSync('changed feature\n');
  await _git(source, ['add', 'feature.txt']);
  await _git(source, ['commit', '--amend', '--no-edit', '-q']);
}

Future<String> _expectRoundTrip(Directory target, Directory collection,
    Directory root, String filename) async {
  final destination = Directory('${root.path}/round-trip')..createSync();
  await _expectSuccess(
      await _export(target, destination, ['--channel', 'master']));
  final actual = File('${destination.path}/$filename').readAsBytesSync();
  expect(actual, File('${collection.path}/$filename').readAsBytesSync());
  return utf8.decode(actual);
}
