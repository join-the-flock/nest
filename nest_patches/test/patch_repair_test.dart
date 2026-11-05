import 'dart:convert';
import 'dart:io';

import 'package:nest_patches/nest_patches.dart';
import 'package:test/test.dart';

void main() {
  late Directory root, source, fork, patches;
  late String base, target, original, originalBranch;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('nest repair tests-');
    source = Directory('${root.path}/source')..createSync();
    fork = Directory('${root.path}/fork');
    patches = Directory('${root.path}/patches')..createSync();
    await _git(source, ['init', '-q']);
    await _configure(source);
    _write(source, 'feature.txt', 'intro\nbase\nend\n');
    _write(source, 'README.md', 'upstream README\n');
    _write(source, '.gitignore', 'cache/\n');
    await _commit(source, 'Base');
    base = await _git(source, ['rev-parse', 'HEAD']);
    await _git(source, ['update-ref', upstreamHead, base]);
    _write(source, 'feature.txt', 'intro\nfork feature\nend\n');
    await _commit(source, 'Feature\n\nPatch-Filename: feature.patch');
    _write(source, 'README.md', 'Flock README\n');
    await _commit(source,
        'README\n\nPatch-Filename: readme.patch\nPatch-Replace-File: README.md');
    await exportPatches(source.path, patches.path, manifest: '.patches-master');
    _write(patches, '.patches-stable',
        File('${patches.path}/.patches-master').readAsStringSync());
    await _run('git', ['clone', '-q', source.path, fork.path]);
    await _configure(fork);
    await _git(fork, ['update-ref', upstreamHead, base]);
    original = await _git(fork, ['rev-parse', 'HEAD']);
    originalBranch = await _git(fork, ['symbolic-ref', 'HEAD']);
    await _git(source, ['checkout', '--detach', '-q', base]);
    _write(source, 'feature.txt', 'intro\nupstream feature\nend\n');
    _write(source, 'README.md', 'new upstream README\n');
    await _commit(source, 'Upstream change');
    target = await _git(source, ['rev-parse', 'HEAD']);
    await _git(fork, ['fetch', '-q', source.path, target]);
    await _git(fork, ['update-ref', 'refs/remotes/origin/master', target]);
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<ProcessResult> repair(List<String> args) =>
      _tool('git_repair_patches', ['--flutter', fork.path, ...args], root);
  Future<ProcessResult> export([List<String> args = const []]) => _tool(
      'git_export_patches',
      ['-f', fork.path, '-p', patches.path, ...args],
      root);
  Future<ProcessResult> start(
      {String? revision, String channel = 'master'}) async {
    if (revision != null) {
      await _git(
          fork, ['update-ref', 'refs/remotes/origin/$channel', revision]);
    }
    return repair([
      '--patches-dir',
      patches.path,
      '--channel',
      channel,
      '--adaptation-date',
      '2026-11-05',
    ]);
  }

  Future<File> journal() async {
    final path = await _git(
        fork, ['rev-parse', '--git-path', 'nest-patch-repair/state.json']);
    return File(path.startsWith('/') ? path : '${fork.path}/$path');
  }

  Future<void> resolve() async {
    _write(fork, 'feature.txt', 'intro\nupstream plus fork\nend\n');
    await _success(await repair(['--continue']));
  }

  test(
      'repairs the current branch, exports a channel adaptation and freshly replays replacements',
      () async {
    final oldFeature = File('${patches.path}/feature.patch').readAsStringSync();
    final oldReadme = File('${patches.path}/readme.patch').readAsStringSync();
    final oldStable =
        File('${patches.path}/.patches-stable').readAsStringSync();
    final stopped = await start();
    expect(stopped.exitCode, isNot(0));
    expect(stopped.stdout, contains('Stopped at patch 1 of 2: feature.patch'));
    expect(await _git(fork, ['symbolic-ref', 'HEAD']), originalBranch);
    expect(await _git(fork, ['rev-parse', 'HEAD']), target);
    expect(File('${fork.path}/feature.txt').readAsStringSync(),
        contains('<<<<<<<'));
    expect((await journal()).existsSync(), isTrue);
    await resolve();
    expect(File('${fork.path}/README.md').readAsStringSync(), 'Flock README\n');
    expect(await _git(fork, ['status', '--porcelain']), isEmpty);
    final message = await _git(fork, ['log', '-1', '--format=%B']);
    expect(message, contains('Patch-Replace-File: README.md'));
    await _success(await repair(['--export']));
    expect((await journal()).existsSync(), isFalse);
    expect(File('${patches.path}/.patches-master').readAsStringSync(),
        'feature_2026-11-05.patch\nreadme.patch\n');
    expect(
        File('${patches.path}/.patches-stable').readAsStringSync(), oldStable);
    expect(
        File('${patches.path}/feature.patch').readAsStringSync(), oldFeature);
    expect(File('${patches.path}/readme.patch').readAsStringSync(), oldReadme);
    expect(await _git(fork, ['log', '-2', '--format=%B']),
        contains('Patch-Filename: feature_2026-11-05.patch'));
    expect(
        await _git(fork, ['show', '-s', '--format=%an <%ae> %aI', 'HEAD^']),
        await _git(
            fork, ['show', '-s', '--format=%an <%ae> %aI', '$original^']));
    final fresh = Directory('${root.path}/fresh');
    await _run('git', ['clone', '-q', source.path, fresh.path]);
    await _configure(fresh);
    await _git(fresh, ['checkout', '--detach', '-q', target]);
    await _success(await _tool('git_import_patches',
        ['-f', fresh.path, '-p', patches.path, '--channel', 'master'], root));
    expect(await _git(fresh, ['rev-parse', 'HEAD^{tree}']),
        await _git(fork, ['rev-parse', 'HEAD^{tree}']));
    await _success(await _tool(
        'git_export_patches',
        [
          '-f',
          fork.path,
          '-p',
          patches.path,
          '--channel',
          'master',
          '--grep',
          'Patch-Filename: feature_2026-11-05.patch',
          '--dry-run'
        ],
        root));
  });

  test(
      'abort discards conflict edits and restores HEAD, branch, base and cache',
      () async {
    _write(fork, 'cache/sdk', 'cached');
    expect((await start()).exitCode, isNot(0));
    _write(fork, 'feature.txt', 'unfinished resolution\n');
    await _success(await repair(['--abort']));
    expect(await _git(fork, ['rev-parse', 'HEAD']), original);
    expect(await _git(fork, ['symbolic-ref', 'HEAD']), originalBranch);
    expect(await _git(fork, ['rev-parse', upstreamHead]), base);
    expect(await _git(fork, ['status', '--porcelain']), isEmpty);
    expect(File('${fork.path}/cache/sdk').readAsStringSync(), 'cached');
    expect((await journal()).existsSync(), isFalse);
  });

  test('a clean replay needs no adaptation and preserves collection bytes',
      () async {
    final before = File('${patches.path}/feature.patch').readAsStringSync();
    await _success(await start(revision: base));
    await _success(await repair(['--export']));
    expect(File('${patches.path}/feature.patch').readAsStringSync(), before);
    expect(File('${patches.path}/.patches-master').readAsStringSync(),
        'feature.patch\nreadme.patch\n');
  });

  for (final channel in ['beta', 'stable']) {
    test('$channel selects its own manifest and origin branch', () async {
      _write(patches, '.patches-$channel', 'readme.patch\n');
      await _git(fork, ['update-ref', 'refs/remotes/origin/master', base]);
      await _success(await start(channel: channel, revision: target));
      expect(await _git(fork, ['rev-parse', upstreamHead]), target);
      expect(File('${fork.path}/feature.txt').readAsStringSync(),
          'intro\nupstream feature\nend\n');
      expect(
          File('${fork.path}/README.md').readAsStringSync(), 'Flock README\n');
      final state = jsonDecode((await journal()).readAsStringSync());
      expect(state['manifest'], '.patches-$channel');
      expect(state['onto'], target);
      await _success(await repair(['--abort']));
    });
  }

  test('resume keeps the target pinned when origin advances', () async {
    await start();
    await _git(fork, ['update-ref', 'refs/remotes/origin/master', base]);
    await resolve();
    await _success(await repair(['--export']));
    expect(await _git(fork, ['rev-parse', upstreamHead]), target);
    expect(await _git(fork, ['rev-parse', 'origin/master']), base);
  });

  test('repair requires a channel and rejects the removed target override',
      () async {
    final refs = await _git(fork, ['show-ref']);
    final missing = await repair(['-p', patches.path]);
    expect(missing.exitCode, isNot(0));
    expect(missing.stderr, contains('requires --patches-dir and --channel'));
    final removed = await repair(
        ['-p', patches.path, '--channel', 'master', '--onto', target]);
    expect(removed.exitCode, isNot(0));
    final help = await repair(['--help']);
    expect(help.stdout, isNot(contains('--onto')));
    expect(help.stdout, isNot(contains('--manifest')));
    expect(await _git(fork, ['show-ref']), refs);
    expect((await journal()).existsSync(), isFalse);
  });

  test('continue refuses unresolved markers and export refuses a paused series',
      () async {
    await start();
    expect((await repair(['--continue'])).stderr,
        contains('Unresolved conflict markers'));
    expect((await repair(['--export'])).stderr, contains('remaining patches'));
    expect((await journal()).existsSync(), isTrue);
  });

  test('existing import/reset cannot overwrite an active repair', () async {
    await start();
    final result = await _tool(
        'git_import_patches',
        ['-f', fork.path, '-p', patches.path, '--channel', 'master', '--reset'],
        root);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('repair is active'));
    expect(File('${fork.path}/feature.txt').readAsStringSync(),
        contains('<<<<<<<'));
  });

  test('repeated start preserves the pending repair', () async {
    await start();
    final state = (await journal()).readAsStringSync();
    expect((await start()).stderr, contains('already active'));
    expect((await journal()).readAsStringSync(), state);
  });

  test('continue rejects conflict markers even after manual staging', () async {
    await start();
    await _git(fork, ['add', 'feature.txt']);
    final result = await repair(['--continue']);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('Unresolved conflict markers'));
    expect((await journal()).existsSync(), isTrue);
  });

  test('continue recovers a Git commit completed before the journal advanced',
      () async {
    await start();
    _write(fork, 'feature.txt', 'intro\nupstream plus fork\nend\n');
    await _git(fork, ['add', 'feature.txt']);
    await _git(fork, ['-c', 'core.editor=true', 'am', '--continue']);
    await _success(await repair(['--continue']));
    expect(await _git(fork, ['rev-list', '--count', '$target..HEAD']), '2');
    await _success(await repair(['--export']));
  });

  test('resume refuses an unrelated Git operation', () async {
    await _success(await start(revision: base));
    final gitDirectory = await _git(fork, ['rev-parse', '--absolute-git-dir']);
    _write(Directory(gitDirectory), 'MERGE_HEAD', '$target\n');
    final head = await _git(fork, ['rev-parse', 'HEAD']);
    expect((await repair(['--abort'])).stderr,
        contains('Git operation is in progress'));
    expect(await _git(fork, ['rev-parse', 'HEAD']), head);
    File('$gitDirectory/MERGE_HEAD').deleteSync();
    await _success(await repair(['--abort']));
  });

  for (final dirty in ['tracked', 'untracked', 'staged']) {
    test('refuses $dirty work before moving history', () async {
      _write(fork, dirty == 'untracked' ? 'local.txt' : 'feature.txt',
          'local work\n');
      if (dirty == 'staged') await _git(fork, ['add', 'feature.txt']);
      final refs = await _git(fork, ['show-ref']);
      expect((await start()).exitCode, isNot(0));
      expect(await _git(fork, ['rev-parse', 'HEAD']), original);
      expect(await _git(fork, ['show-ref']), refs);
      expect((await journal()).existsSync(), isFalse);
    });
  }

  test('export refuses concurrent collection edits and retains the repair',
      () async {
    await start();
    await resolve();
    _write(patches, 'feature.patch', 'concurrent edit\n');
    final result = await repair(['--export']);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('collection changed'));
    expect((await journal()).existsSync(), isTrue);
    expect(File('${patches.path}/feature.patch').readAsStringSync(),
        'concurrent edit\n');
  });

  test('standard export includes development commits after a clean repair',
      () async {
    await _success(await start(revision: base));
    _write(fork, 'extra.txt', 'unexported\n');
    await _commit(fork, 'Unexported change');
    await _success(await export());
    expect(File('${patches.path}/.patches-master').readAsStringSync(),
        'feature.patch\nreadme.patch\nunexported_change.patch\n');
    expect(File('${patches.path}/unexported_change.patch').readAsStringSync(),
        contains('+unexported'));
    expect((await journal()).existsSync(), isFalse);
  });

  test(
      'one standard export combines adaptations, development edits, binary files and replacement intent',
      () async {
    final originalFeature =
        File('${patches.path}/feature.patch').readAsStringSync();
    final stable = File('${patches.path}/.patches-stable').readAsStringSync();
    await start();
    await resolve();
    _write(
        fork, 'feature.txt', 'intro\nupstream plus fork\nend\nnew feature\n');
    File('${fork.path}/image.png')
        .writeAsBytesSync(List.generate(512, (i) => i % 256));
    await _commit(fork, 'Add extra feature');
    _write(fork, 'README.md', 'New development README\n');
    await _commit(fork, 'Refresh README\n\nPatch-Replace-File: README.md');
    final tree = await _git(fork, ['rev-parse', 'HEAD^{tree}']);
    final author = await _git(fork, ['show', '-s', '--format=%an <%ae> %aI']);
    await _success(await export(['--channel', 'master']));
    expect((await journal()).existsSync(), isFalse);
    expect(File('${patches.path}/.patches-master').readAsStringSync(),
        'feature_2026-11-05.patch\nreadme.patch\nadd_extra_feature.patch\nrefresh_readme.patch\n');
    expect(File('${patches.path}/.patches-stable').readAsStringSync(), stable);
    expect(File('${patches.path}/feature.patch').readAsStringSync(),
        originalFeature);
    expect(File('${patches.path}/refresh_readme.patch').readAsStringSync(),
        contains('replace file mode 100644'));
    expect(File('${patches.path}/add_extra_feature.patch').readAsStringSync(),
        contains('GIT binary patch'));
    expect(await _git(fork, ['show', '-s', '--format=%an <%ae> %aI']), author);
    expect(await _git(fork, ['rev-parse', 'HEAD^{tree}']), tree);
    final fresh = Directory('${root.path}/combined-fresh');
    await _run('git', ['clone', '-q', source.path, fresh.path]);
    await _configure(fresh);
    await _git(fresh, ['checkout', '--detach', '-q', target]);
    await _success(await _tool('git_import_patches',
        ['-f', fresh.path, '-p', patches.path, '--channel', 'master'], root));
    expect(await _git(fresh, ['rev-parse', 'HEAD^{tree}']), tree);
  });

  test(
      'standard export dry run leaves history, collection and session unchanged',
      () async {
    await start();
    await resolve();
    _write(fork, 'new.txt', 'development\n');
    await _commit(fork, 'New development');
    final head = await _git(fork, ['rev-parse', 'HEAD']);
    final refs = await _git(fork, ['show-ref']);
    final state = (await journal()).readAsStringSync();
    final manifest = File('${patches.path}/.patches-master').readAsStringSync();
    final result = await export(['--dry-run']);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('Export would change'));
    expect(await _git(fork, ['rev-parse', 'HEAD']), head);
    expect(await _git(fork, ['show-ref']), refs);
    expect((await journal()).readAsStringSync(), state);
    expect(
        File('${patches.path}/.patches-master').readAsStringSync(), manifest);
    expect(File('${patches.path}/new_development.patch').existsSync(), isFalse);
    expect(
        File('${patches.path}/feature_2026-11-05.patch').existsSync(), isFalse);
    await _success(await export());
  });

  test('no-change export dry run retains a completed repair', () async {
    await _success(await start(revision: base));
    final state = (await journal()).readAsStringSync();
    final head = await _git(fork, ['rev-parse', 'HEAD']);
    await _success(await export(['--dry-run']));
    expect((await journal()).readAsStringSync(), state);
    expect(await _git(fork, ['rev-parse', 'HEAD']), head);
  });

  test('development commits retain the normal shared-patch protection',
      () async {
    await start();
    await resolve();
    _write(fork, 'README.md', 'extended README\n');
    await _commit(fork, 'Extend README\n\nPatch-Filename: readme.patch');
    final originalReadme =
        File('${patches.path}/readme.patch').readAsStringSync();
    final state = (await journal()).readAsStringSync();
    final head = await _git(fork, ['rev-parse', 'HEAD']);
    final result = await export();
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('shared with another manifest'));
    expect(File('${patches.path}/readme.patch').readAsStringSync(),
        originalReadme);
    expect((await journal()).readAsStringSync(), state);
    expect(await _git(fork, ['rev-parse', 'HEAD']), head);
    await _success(await export(['--update-shared']));
    expect((await journal()).existsSync(), isFalse);
    expect(File('${patches.path}/readme.patch').readAsStringSync(),
        contains('+extended README'));
  });

  test('standard export refuses unfinished repair and mismatched selections',
      () async {
    await start();
    expect((await export()).stderr, contains('repair is unfinished'));
    await resolve();
    final state = (await journal()).readAsStringSync();
    final head = await _git(fork, ['rev-parse', 'HEAD']);
    expect((await export(['--channel', 'stable'])).stderr,
        contains('active repair manifest'));
    expect((await export(['--grep', 'README'])).stderr,
        contains('complete history'));
    expect((await export([base])).stderr, contains('complete history'));
    final other = Directory('${root.path}/other-patches')..createSync();
    expect(
        (await _tool(
                'git_export_patches',
                ['-f', fork.path, '-p', other.path, '--channel', 'master'],
                root))
            .stderr,
        contains('active repair patch collection'));
    expect((await journal()).readAsStringSync(), state);
    expect(await _git(fork, ['rev-parse', 'HEAD']), head);
  });

  test(
      'rewriting the completed repair checkpoint refuses export without losing changes',
      () async {
    await _success(await start(revision: base));
    _write(fork, 'extra.txt', 'amended history\n');
    await _git(fork, ['add', '.']);
    await _git(fork, ['commit', '--amend', '--no-edit', '-q']);
    final head = await _git(fork, ['rev-parse', 'HEAD']);
    final result = await export();
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('completed repair history was rewritten'));
    expect(await _git(fork, ['rev-parse', 'HEAD']), head);
    expect((await journal()).existsSync(), isTrue);
  });

  test('invalid ref and date fail before a session or backup is created',
      () async {
    final refs = await _git(fork, ['show-ref']);
    await _git(fork, ['update-ref', '-d', 'refs/remotes/origin/master']);
    final missing = await start();
    expect(missing.exitCode, isNot(0));
    expect(missing.stderr, contains('Fetch origin'));
    await _git(fork, ['update-ref', 'refs/remotes/origin/master', target]);
    expect(
        (await repair([
          '-p',
          patches.path,
          '--channel',
          'master',
          '--adaptation-date',
          '2026-02-30'
        ]))
            .exitCode,
        isNot(0));
    expect(await _git(fork, ['show-ref']), refs);
    expect((await journal()).existsSync(), isFalse);
  });

  test('lost recorded base can be supplied explicitly', () async {
    await _git(fork, ['update-ref', '-d', upstreamHead]);
    final result = await repair(
        ['-p', patches.path, '--channel', 'master', '--base', base]);
    expect(result.exitCode, isNot(0));
    expect(result.stdout, contains('Stopped at patch'));
    final state = jsonDecode((await journal()).readAsStringSync());
    expect(state['originalBase'], isNull);
    await _success(await repair(['--abort']));
    final ref = await Process.run('git',
        ['-C', fork.path, 'show-ref', '--verify', '--quiet', upstreamHead]);
    expect(ref.exitCode, 1);
  });

  test('a resolution can keep upstream content and drop the obsolete patch',
      () async {
    await start();
    _write(fork, 'feature.txt', 'intro\nupstream feature\nend\n');
    await _success(await repair(['--continue']));
    await _success(await repair(['--export']));
    expect(await _git(fork, ['rev-list', '--count', '$target..HEAD']), '1');
    expect(File('${patches.path}/.patches-master').readAsStringSync(),
        'readme.patch\n');
    expect(File('${patches.path}/feature.patch').existsSync(), isTrue);
  });

  test(
      'a single mail can combine unconditional replacement and ordinary conflicts',
      () async {
    await _git(source, ['checkout', '--detach', '-q', '$original^']);
    _write(source, 'README.md', 'mixed replacement\n');
    await _git(source, ['add', '.']);
    await _git(source, [
      'commit',
      '--amend',
      '-qm',
      'Feature\n\nPatch-Filename: feature.patch\nPatch-Replace-File: README.md'
    ]);
    await exportPatches(source.path, patches.path,
        manifest: '.patches-master', updateShared: true);
    expect((await start()).stdout, contains('Stopped at patch'));
    await resolve();
    expect(File('${fork.path}/README.md').readAsStringSync(),
        'mixed replacement\n');
    await _success(await repair(['--export']));
    expect(File('${patches.path}/feature_2026-11-05.patch').readAsStringSync(),
        contains('replace file mode 100644'));
  });

  test('reconstructs missing fork preimages and can pause more than once',
      () async {
    await _git(source, ['checkout', '--detach', '-q', original]);
    _write(source, 'feature.txt', 'intro\nfollow-up fork feature\nend\n');
    await _commit(source, 'Follow-up\n\nPatch-Filename: followup.patch');
    await exportPatches(source.path, patches.path, manifest: '.patches-master');
    final forkBlob = await _git(source, ['rev-parse', '$original:feature.txt']);
    fork.deleteSync(recursive: true);
    fork.createSync();
    await _git(fork, ['init', '-q']);
    await _configure(fork);
    await _git(fork, ['fetch', '-q', source.path, target]);
    await _git(fork, ['reset', '--hard', 'FETCH_HEAD']);
    await _git(fork, ['update-ref', upstreamHead, base]);
    final missing =
        await Process.run('git', ['-C', fork.path, 'cat-file', '-e', forkBlob]);
    expect(missing.exitCode, isNot(0));
    expect((await start(revision: target)).stdout,
        contains('Stopped at patch 1 of 3'));
    await _git(fork, ['cat-file', '-e', forkBlob]);
    _write(fork, 'feature.txt', 'intro\nupstream plus fork\nend\n');
    final second = await repair(['--continue']);
    expect(second.exitCode, isNot(0));
    expect(second.stdout, contains('Stopped at patch 3 of 3: followup.patch'));
    _write(fork, 'feature.txt', 'intro\nupstream plus follow-up fork\nend\n');
    await _success(await repair(['--continue']));
    await _success(await repair(['--export']));
    expect(File('${patches.path}/.patches-master').readAsStringSync(),
        'feature_2026-11-05.patch\nreadme.patch\nfollowup_2026-11-05.patch\n');
  });

  test('incompatible old base fails before moving the branch', () async {
    final refs = await _git(fork, ['show-ref']);
    final result = await repair(
        ['-p', patches.path, '--channel', 'master', '--base', target]);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('Cannot reconstruct'));
    expect(await _git(fork, ['show-ref']), refs);
    expect((await journal()).existsSync(), isFalse);
  });

  test('refuses to abort on a different branch', () async {
    await start();
    await _git(fork, ['am', '--abort']);
    await _git(fork, ['checkout', '-qb', 'other-branch']);
    expect((await repair(['--abort'])).stderr, contains('branch changed'));
    expect(
        await _git(fork, ['symbolic-ref', 'HEAD']), 'refs/heads/other-branch');
    expect((await journal()).existsSync(), isTrue);
  });

  test('resume flags reject contradictory options and missing sessions',
      () async {
    expect((await repair(['--continue'])).stderr, contains('No patch repair'));
    expect((await repair(['--continue', '--abort'])).stderr,
        contains('Choose one'));
    expect((await repair(['--continue', '--channel', 'master'])).stderr,
        contains('saved session'));
    expect((await _tool('git_repair_patches', ['--help'], root)).exitCode, 0);
  });
}

void _write(Directory directory, String path, String contents) {
  final file = File('${directory.path}/$path');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

Future<ProcessResult> _tool(
        String name, List<String> arguments, Directory cwd) =>
    Process.run(Platform.resolvedExecutable,
        ['run', '${Directory.current.path}/bin/$name.dart', ...arguments],
        workingDirectory: cwd.path);

Future<void> _success(ProcessResult result) async =>
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

Future<String> _run(String command, List<String> arguments) async {
  final result = await Process.run(command, arguments);
  await _success(result);
  return (result.stdout as String).trim();
}

Future<String> _git(Directory directory, List<String> arguments) =>
    _run('git', ['-C', directory.path, ...arguments]);

Future<void> _commit(Directory directory, String message) async {
  await _git(directory, ['add', '.']);
  await _git(directory, ['commit', '-qm', message]);
}

Future<void> _configure(Directory directory) async {
  await _git(directory, ['config', 'user.name', 'Nest tests']);
  await _git(directory, ['config', 'user.email', 'nest@example.invalid']);
  await _git(directory, ['config', 'commit.gpgsign', 'false']);
  await _git(directory, ['config', 'core.hooksPath', '/dev/null']);
}
