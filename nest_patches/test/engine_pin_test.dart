import 'dart:io';
import 'package:nest_patches/nest_patches.dart';
import 'package:test/test.dart';

void main() {
  late Directory root, sdk, patches;
  late String upstream, patch, engine;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('nest engine pin ');
    sdk = Directory('${root.path}/sdk')..createSync();
    patches = Directory('${root.path}/patches')..createSync();
    await git(sdk.path, ['init', '-q']);
    for (final entry in {
      'user.name': 'Engine test',
      'user.email': 'engine@example.invalid',
      'commit.gpgsign': 'false',
      'core.hooksPath': '/dev/null'
    }.entries) {
      await git(sdk.path, ['config', entry.key, entry.value]);
    }
    write(sdk, '.gitignore', 'bin/internal/engine.version\nbin/cache/\n');
    write(sdk, 'engine/source.txt', 'upstream engine\n');
    write(sdk, 'bin/internal/update_engine_version.sh', r'''#!/bin/bash
set -e
mkdir -p bin/cache
if [ -n "${FLUTTER_PREBUILT_ENGINE_VERSION:-}" ]; then
  echo "$FLUTTER_PREBUILT_ENGINE_VERSION" > bin/cache/engine.stamp
elif git ls-files --error-unmatch bin/internal/engine.version >/dev/null 2>&1; then
  cp bin/internal/engine.version bin/cache/engine.stamp
else
  git rev-parse HEAD:engine > bin/cache/engine.stamp
fi
''');
    await commit(sdk, 'Upstream');
    upstream = (await git(sdk.path, ['rev-parse', 'HEAD'])).trim();
    engine = (await git(sdk.path, ['rev-parse', 'HEAD:engine'])).trim();
    write(sdk, 'engine/source.txt', 'fork engine patch\n');
    write(sdk, 'feature.txt', 'first feature\n');
    await commit(sdk, 'First feature\n\nPatch-Filename: feature.patch');
    patch = await git(sdk.path, ['format-patch', '-1', '--stdout']);
    await git(sdk.path, ['reset', '--hard', upstream]);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('import pins before engine changes; reset preserves that base',
      () async {
    await importPatches(sdk.path, patch);
    final base = (await git(sdk.path, ['rev-parse', upstreamHead])).trim();
    expect(await git(sdk.path, ['rev-parse', '$base^']), '$upstream\n');
    expect(await git(sdk.path, ['show', '$base:bin/internal/engine.version']),
        '$engine\n');
    expect(await git(sdk.path, ['status', '--porcelain']), isEmpty);
    final result = await Process.run(
        'bash', ['bin/internal/update_engine_version.sh'],
        workingDirectory: sdk.path);
    expect(result.exitCode, 0);
    expect(File('${sdk.path}/bin/cache/engine.stamp').readAsStringSync(),
        '$engine\n');
    expect((await git(sdk.path, ['rev-parse', 'HEAD:engine'])).trim(),
        isNot(engine));
    await importPatches(sdk.path, patch, reset: true);
    expect((await git(sdk.path, ['rev-parse', upstreamHead])).trim(), base);
  });

  test('even explicit export ranges exclude engine pin metadata', () async {
    await importPatches(sdk.path, patch);
    await exportPatches(sdk.path, patches.path, patchRange: '$upstream..HEAD');
    expect(
        File('${patches.path}/.patches').readAsStringSync(), 'feature.patch\n');
    expect(File('${patches.path}/feature.patch').readAsStringSync(),
        isNot(contains('engine.version')));
  });

  test(
      'publication retains the tree but no pin ancestors and leaves local history intact',
      () async {
    await importPatches(sdk.path, patch);
    write(sdk, 'second.txt', 'second feature\n');
    await commit(sdk, 'Second feature\n\nPatch-Filename: second.patch');
    final head = (await git(sdk.path, ['rev-parse', 'HEAD'])).trim();
    final pin = (await git(sdk.path, ['rev-parse', upstreamHead])).trim();
    final refs = await git(sdk.path, ['show-ref']);
    final published = await publicationRevision(sdk.path);
    expect(await git(sdk.path, ['rev-parse', '$published^{tree}']),
        await git(sdk.path, ['rev-parse', '$head^{tree}']));
    expect(await git(sdk.path, ['log', '--format=%B', '$upstream..$published']),
        isNot(contains('Nest-Engine-Pin: true')));
    expect(
        await git(sdk.path, ['rev-list', '--count', '$upstream..$published']),
        '2\n');
    expect(
        (await Process.run('git', [
          '-C',
          sdk.path,
          'merge-base',
          '--is-ancestor',
          pin,
          published
        ]))
            .exitCode,
        1);
    expect(await git(sdk.path, ['rev-parse', 'HEAD']), '$head\n');
    expect(await git(sdk.path, ['show-ref']), refs);
    expect(await git(sdk.path, ['status', '--porcelain']), isEmpty);
    expect(await publicationRevision(sdk.path), published);
    final remote = Directory('${root.path}/remote.git');
    await git(sdk.path, ['init', '--bare', remote.path]);
    await git(sdk.path, ['push', remote.path, '$published:refs/heads/master']);
    final clone = Directory('${root.path}/clone');
    await git(
        sdk.path, ['clone', '--branch', 'master', remote.path, clone.path]);
    await exportPatches(clone.path, patches.path,
        patchRange: '$upstream..HEAD');
    expect(File('${patches.path}/.patches').readAsStringSync(),
        'feature.patch\nsecond.patch\n');
    expect(File('${patches.path}/feature.patch').readAsStringSync(),
        isNot(contains('engine.version')));
  });

  test('later custom engine pins fold into the final patch', () async {
    await importPatches(sdk.path, patch);
    final custom = 'b' * 40;
    await pinEngine(sdk.path, version: custom);
    final published = await publicationRevision(sdk.path);
    expect(
        await git(sdk.path, ['show', '$published:bin/internal/engine.version']),
        '$custom\n');
    expect(
        await git(sdk.path, ['rev-list', '--count', '$upstream..$published']),
        '1\n');
  });

  test('stable tracked pins need no generated commit', () async {
    write(sdk, 'bin/internal/engine.version', '${'c' * 40}\n');
    await git(sdk.path, ['add', '-f', 'bin/internal/engine.version']);
    await git(sdk.path, ['commit', '-qm', 'Upstream stable pin']);
    final head = (await git(sdk.path, ['rev-parse', 'HEAD'])).trim();
    expect(await pinEngine(sdk.path), head);
    expect(await publicationRevision(sdk.path), head);
  });

  test('refuses pin markers on commits with other changes', () async {
    await importPatches(sdk.path, patch);
    write(sdk, 'unexpected.txt', 'must not be dropped\n');
    await commit(sdk, 'Feature\n\nNest-Engine-Pin: true');
    await expectLater(publicationRevision(sdk.path), throwsFormatException);
  });

  test('refuses to pin dirty checkouts without discarding edits', () async {
    write(sdk, 'engine/source.txt', 'local edit\n');
    await expectLater(importPatches(sdk.path, patch), throwsFormatException);
    expect(await git(sdk.path, ['rev-parse', 'HEAD']), '$upstream\n');
    expect(File('${sdk.path}/engine/source.txt').readAsStringSync(),
        'local edit\n');
  });

  test('repair repins fetched upstream; abort restores the original pin',
      () async {
    write(sdk, 'engine/new.txt', 'new upstream dependency\n');
    await commit(sdk, 'New upstream');
    final target = (await git(sdk.path, ['rev-parse', 'HEAD'])).trim();
    final targetEngine =
        (await git(sdk.path, ['rev-parse', 'HEAD:engine'])).trim();
    await git(sdk.path, ['update-ref', 'refs/remotes/origin/master', target]);
    await git(sdk.path, ['reset', '--hard', upstream]);
    await importPatches(sdk.path, patch);
    final original = await git(sdk.path, ['rev-parse', 'HEAD']);
    final originalBase = await git(sdk.path, ['rev-parse', upstreamHead]);
    write(patches, '.patches-master', 'feature.patch\n');
    write(patches, 'feature.patch', patch);
    final tool = File('bin/git_repair_patches.dart').absolute.path;
    Future<ProcessResult> repair(List<String> args) => Process.run(
        Platform.resolvedExecutable,
        ['run', tool, '--flutter', sdk.path, ...args]);
    final start =
        await repair(['--patches-dir', patches.path, '--channel', 'master']);
    expect(start.exitCode, 0, reason: '${start.stdout}${start.stderr}');
    final pinned = (await git(sdk.path, ['rev-parse', upstreamHead])).trim();
    expect(await git(sdk.path, ['rev-parse', '$pinned^']), '$target\n');
    expect(File('${sdk.path}/bin/internal/engine.version').readAsStringSync(),
        '$targetEngine\n');
    await expectLater(publicationRevision(sdk.path), throwsFormatException);
    final abort = await repair(['--abort']);
    expect(abort.exitCode, 0, reason: '${abort.stderr}');
    expect(await git(sdk.path, ['rev-parse', 'HEAD']), original);
    expect(await git(sdk.path, ['rev-parse', upstreamHead]), originalBase);
    expect(File('${sdk.path}/bin/internal/engine.version').readAsStringSync(),
        '$engine\n');
  });

  test('publication refuses merges after a pin without changing HEAD',
      () async {
    await importPatches(sdk.path, patch);
    await git(sdk.path, ['checkout', '-qb', 'side']);
    write(sdk, 'side.txt', 'side\n');
    await commit(sdk, 'Side');
    await git(sdk.path, ['checkout', '-qb', 'mainline', 'HEAD^']);
    write(sdk, 'main.txt', 'main\n');
    await commit(sdk, 'Main');
    await git(sdk.path, ['merge', '--no-ff', '-m', 'Merge side', 'side']);
    final head = await git(sdk.path, ['rev-parse', 'HEAD']);
    await expectLater(publicationRevision(sdk.path), throwsFormatException);
    expect(await git(sdk.path, ['rev-parse', 'HEAD']), head);
  });

  test('publication refuses a bare pin or dirty checkout', () async {
    await pinEngine(sdk.path);
    await expectLater(publicationRevision(sdk.path), throwsFormatException);
    write(sdk, 'untracked.txt', 'keep me\n');
    await expectLater(publicationRevision(sdk.path), throwsFormatException);
    expect(File('${sdk.path}/untracked.txt').readAsStringSync(), 'keep me\n');
  });

  test('ignores inherited engine overrides while selecting upstream', () async {
    final tool = File('bin/git_pin_engine.dart').absolute.path;
    final result = await Process.run(
        Platform.resolvedExecutable, ['run', tool, '--flutter', sdk.path],
        environment: {'FLUTTER_PREBUILT_ENGINE_VERSION': 'd' * 40});
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(File('${sdk.path}/bin/internal/engine.version').readAsStringSync(),
        '$engine\n');
  });
}

void write(Directory repo, String path, String data) {
  final file = File('${repo.path}/$path');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(data);
}

Future<void> commit(Directory repo, String message) async {
  await git(repo.path, ['add', '.']);
  await git(repo.path, ['commit', '-qm', message]);
}

Future<String> git(String repo, List<String> args) async {
  final result = await Process.run('git', ['-C', repo, ...args]);
  if (result.exitCode != 0) throw StateError('$args: ${result.stderr}');
  return result.stdout as String;
}
