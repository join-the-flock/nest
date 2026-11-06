part of 'patch_git.dart';

/// Build a publication revision without changing the development checkout.
/// Generated engine-pin commits are omitted; their file contents are carried by
/// the patch commits, so the published SDK retains exactly the validated tree.
Future<String> publicationRevision(String repository) async {
  await _requireCleanReset(repository);
  await _checkRepairOperations(repository);
  if ((await _repairDirectory(repository)).existsSync()) {
    throw FormatException('Complete or abort patch repair before publication');
  }
  final head = (await git(repository, ['rev-parse', 'HEAD'])).trim();
  final pins = (await git(repository, [
    'log',
    '--format=%H',
    '--fixed-strings',
    '--grep=$_enginePinMarker',
    head,
  ]))
      .split('\n')
      .where((line) => line.isNotEmpty)
      .toSet();
  if (pins.isEmpty) return head;
  String? oldest;
  for (final commit in (await git(
          repository, ['rev-list', '--first-parent', '--reverse', head]))
      .split('\n')
      .where((line) => line.isNotEmpty)) {
    if (pins.contains(commit)) {
      oldest = commit;
      break;
    }
  }
  if (oldest == null) {
    throw FormatException(
        'Engine pin is on a merged branch; publish a linear patch series');
  }
  final base = (await git(repository, ['rev-parse', '$oldest^'])).trim();
  final commits = (await git(repository,
          ['rev-list', '--reverse', '--topo-order', '$base..$head']))
      .split('\n')
      .where((line) => line.isNotEmpty)
      .toList();
  final patches = <String>[];
  var previous = base;
  for (final commit in commits) {
    final parents =
        (await git(repository, ['show', '-s', '--format=%P', commit]))
            .trim()
            .split(' ');
    if (parents.length != 1 || parents.single != previous) {
      throw FormatException(
          'Publication requires a linear series after the engine pin');
    }
    previous = commit;
    if (!pins.contains(commit)) {
      patches.add(commit);
      continue;
    }
    final paths = (await git(repository,
            ['diff-tree', '--no-commit-id', '--name-only', '-r', commit]))
        .trim();
    final pin =
        (await git(repository, ['show', '$commit:$_engineVersionPath'])).trim();
    if (paths != _engineVersionPath ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(pin)) {
      throw FormatException(
          'Engine pin commit $commit contains unexpected changes');
    }
  }
  if (patches.isEmpty) {
    throw FormatException(
        'No patch commits to publish after the local engine pin');
  }
  var parent = base;
  for (final commit in patches) {
    final tree = (await git(repository,
            ['rev-parse', '${commit == patches.last ? head : commit}^{tree}']))
        .trim();
    final identity = (await git(repository, [
      'show',
      '-s',
      '--format=%an%x00%ae%x00%aI%x00%cn%x00%ce%x00%cI',
      commit,
    ]))
        .trimRight()
        .split('\x00');
    final message =
        (await git(repository, ['show', '-s', '--format=%B', commit]))
            .trimRight();
    parent = (await git(repository, [
      '-c',
      'commit.gpgsign=false',
      'commit-tree',
      tree,
      '-p',
      parent,
      '-m',
      message
    ], environment: {
      'GIT_AUTHOR_NAME': identity[0],
      'GIT_AUTHOR_EMAIL': identity[1],
      'GIT_AUTHOR_DATE': identity[2],
      'GIT_COMMITTER_NAME': identity[3],
      'GIT_COMMITTER_EMAIL': identity[4],
      'GIT_COMMITTER_DATE': identity[5],
    }))
        .trim();
  }
  final originalTree =
      (await git(repository, ['rev-parse', '$head^{tree}'])).trim();
  final publishedTree =
      (await git(repository, ['rev-parse', '$parent^{tree}'])).trim();
  if (originalTree != publishedTree) {
    throw StateError('Publication changed the validated SDK tree');
  }
  return parent;
}
