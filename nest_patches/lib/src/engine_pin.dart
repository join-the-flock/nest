part of 'patch_git.dart';

const _engineVersionPath = 'bin/internal/engine.version';
const _enginePinMarker = 'Nest-Engine-Pin: true';

/// Pin Flutter's engine before applying fork patches. Generic Git repositories
/// without Flutter's engine-selection script are left unchanged.
Future<String> pinEngine(String repository, {String? version}) async {
  final head = (await git(repository, ['rev-parse', 'HEAD'])).trim();
  const script = 'bin/internal/update_engine_version.sh';
  final tracked = await Process.run(
      'git', ['-C', repository, 'ls-files', '--error-unmatch', script]);
  if (tracked.exitCode != 0) {
    if (version != null) {
      throw FormatException('Cannot pin an engine in a non-Flutter checkout');
    }
    return head;
  }
  await _requireCleanReset(repository);
  await git(repository, ['var', 'GIT_COMMITTER_IDENT']);
  if (version == null) {
    final result = await Process.run('bash', [script],
        workingDirectory: repository,
        environment: {
          'FLUTTER_PREBUILT_ENGINE_VERSION': '',
          'FLUTTER_REALM': '',
        });
    if (result.exitCode != 0) {
      throw ProcessException('bash', [script],
          '${result.stdout}${result.stderr}', result.exitCode);
    }
    version = File(p.join(repository, 'bin/cache/engine.stamp'))
        .readAsStringSync()
        .trim();
  }
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(version)) {
    throw FormatException('Invalid engine version: $version');
  }
  final existing = await Process.run(
      'git', ['-C', repository, 'show', 'HEAD:$_engineVersionPath']);
  if (existing.exitCode == 0 && (existing.stdout as String).trim() == version)
    return head;
  final file = File(p.join(repository, _engineVersionPath));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('$version\n');
  await git(repository, ['add', '-f', '--', _engineVersionPath]);
  await git(repository, [
    '-c',
    'commit.gpgsign=false',
    'commit',
    '--only',
    '-m',
    'Pin engine for local assembly\n\n$_enginePinMarker',
    '--',
    _engineVersionPath,
  ]);
  return (await git(repository, ['rev-parse', 'HEAD'])).trim();
}
