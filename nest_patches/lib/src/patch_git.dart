// Copyright (c) Electron contributors
// Copyright (c) 2013-2020 GitHub Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to
// the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
// LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
// OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
// WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'patch_collection.dart';
import 'patch_protocol.dart';

part 'patch_repair.dart';

const upstreamHead = 'refs/patches/upstream-head';

Future<String> git(String repository, List<String> arguments,
    {Map<String, String>? environment}) async {
  final result = await Process.run('git', ['-C', repository, ...arguments],
      environment: environment);
  if (result.exitCode != 0) {
    throw ProcessException('git', ['-C', repository, ...arguments],
        '${result.stdout}${result.stderr}', result.exitCode);
  }
  return result.stdout as String;
}

Future<void> importPatches(String repository, String patchData,
    {bool threeway = false, bool reset = false}) async {
  final mails = splitPatches(patchData).map(PatchMail.parse).toList();
  if (mails.isEmpty)
    throw FormatException('The patch collection contains no mail patches');
  final head =
      (await git(repository, ['rev-parse', '--verify', 'HEAD^{commit}']))
          .trim();
  final recorded = await _recordedUpstream(repository);
  await _checkImportHistory(repository, head, recorded, reset: reset);
  for (final mail in mails) {
    if (mail.replacementPaths.isNotEmpty) {
      throw FormatException(
          'Patch-Replace-File is reserved import metadata; use replace file mode');
    }
  }
  final extended = mails
      .any((mail) => mail.files.any((file) => file.replacementMode != null));
  final base = reset ? recorded! : head;
  final destinations = <String>{};
  if (reset) await _validateResetPatches(repository, mails, destinations);
  String? backup;
  if (reset) {
    await _checkIgnoredCollisions(repository, head, base, destinations);
    // Recheck immediately before changing history, after input validation.
    if ((await git(repository, ['rev-parse', 'HEAD'])).trim() != head) {
      throw FormatException('HEAD changed during validation; retry the import');
    }
    await _requireCleanReset(repository);
    await git(repository, ['var', 'GIT_COMMITTER_IDENT']);
    backup =
        'refs/patches/backups/${DateTime.now().toUtc().microsecondsSinceEpoch}-$head';
    await git(repository, ['update-ref', backup, head, '0' * head.length]);
    stdout.writeln('Saved previous HEAD at $backup');
    await git(repository, ['reset', '--hard', base]);
  }
  try {
    if (extended) {
      patchData =
          await _prepareReplacements(repository, mails, threeway: threeway);
    }
    await git(repository, ['update-ref', upstreamHead, base]);
    await _applyMail(repository, patchData,
        threeway: threeway,
        keepEmpty: extended,
        preserveWhitespace: extended || reset);
  } catch (error) {
    if (!reset) rethrow;
    try {
      await _restoreImportBase(repository, base);
    } catch (cleanup) {
      throw ProcessException(
          'git',
          ['am'],
          'Patch import failed: $error\nCould not restore the upstream base: $cleanup\n'
              'The previous history is saved at $backup',
          1);
    }
    throw ProcessException(
        'git',
        ['am'],
        'Patch import failed. Restored checkout to recorded upstream base $base; '
            'no patches remain applied.\nThe previous history is saved at $backup\n$error',
        1);
  }
}

Future<void> _applyMail(String repository, String patchData,
    {required bool threeway,
    required bool keepEmpty,
    required bool preserveWhitespace,
    bool quiet = false}) async {
  final arguments = [
    '-C',
    repository,
    '-c',
    'commit.gpgsign=false',
    'am',
    if (threeway) '--3way',
    if (keepEmpty) '--empty=keep',
    if (preserveWhitespace) '--whitespace=nowarn',
    '--keep-cr'
  ];
  final process = await Process.start('git', arguments);
  final output =
      quiet ? process.stdout.drain<void>() : stdout.addStream(process.stdout);
  final errors =
      quiet ? process.stderr.drain<void>() : stderr.addStream(process.stderr);
  IOException? inputError;
  try {
    process.stdin.add(utf8.encode(patchData));
    await process.stdin.close();
  } on IOException catch (error) {
    inputError = error;
  }
  final code = await process.exitCode;
  await Future.wait([output, errors]);
  if (code != 0)
    throw ProcessException('git', arguments, 'Patch import failed', code);
  if (inputError != null) throw inputError;
}

Future<void> _restoreImportBase(String repository, String base) async {
  final path =
      (await git(repository, ['rev-parse', '--git-path', 'rebase-apply']))
          .trim();
  if (Directory(p.isAbsolute(path) ? path : p.join(repository, path))
      .existsSync()) {
    try {
      await git(repository, ['am', '--abort']);
    } on ProcessException {
      // If abort cannot restore its starting state, clear its bookkeeping and
      // explicitly restore the base selected before this reset/import attempt.
      await git(repository, ['am', '--quit']);
    }
  }
  await git(repository, ['reset', '--hard', base]);
}

Future<void> _validateResetPatches(
    String repository, List<PatchMail> mails, Set<String> destinations) async {
  final temporary =
      Directory.systemTemp.createTempSync('nest-import-validation-');
  try {
    final patch = File('${temporary.path}/patch');
    for (final mail in mails) {
      await _validateMail(repository, mail, temporary);
      await _inspectMailFiles(repository, mail, patch,
          destinations: destinations);
    }
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

/// Never infer an upstream base from a branch name or a fetched remote ref.
Future<String?> _recordedUpstream(String repository) async {
  final exists = await Process.run('git',
      ['-C', repository, 'show-ref', '--verify', '--quiet', upstreamHead]);
  if (exists.exitCode == 1) return null;
  if (exists.exitCode != 0) {
    throw FormatException(
        'Cannot read recorded upstream $upstreamHead: ${exists.stderr}');
  }
  try {
    return (await git(
            repository, ['rev-parse', '--verify', '$upstreamHead^{commit}']))
        .trim();
  } on ProcessException {
    throw FormatException(
        'Recorded upstream $upstreamHead must point to a commit');
  }
}

Future<void> _checkImportHistory(
    String repository, String head, String? recorded,
    {required bool reset}) async {
  if ((await _repairDirectory(repository)).existsSync()) {
    throw FormatException(
        'A patch repair is active; use repair --continue, --export, or --abort');
  }
  for (final operation in [
    'rebase-apply',
    'rebase-merge',
    'MERGE_HEAD',
    'CHERRY_PICK_HEAD',
    'REVERT_HEAD',
    'sequencer'
  ]) {
    final path =
        (await git(repository, ['rev-parse', '--git-path', operation])).trim();
    if (FileSystemEntity.typeSync(
            p.isAbsolute(path) ? path : p.join(repository, path)) !=
        FileSystemEntityType.notFound) {
      throw FormatException(
          'A Git operation is in progress ($operation). Complete or abort it before importing patches');
    }
  }
  if (reset) {
    if (recorded == null) {
      throw FormatException(
          'Cannot --reset without a recorded upstream base ($upstreamHead). '
          'Start with a fresh upstream checkout and import once; no base will be guessed');
    }
    final ancestor = await Process.run('git',
        ['-C', repository, 'merge-base', '--is-ancestor', recorded, head]);
    if (ancestor.exitCode != 0) {
      throw FormatException(
          'Recorded upstream is not an ancestor of HEAD; refusing to reset an unrelated history');
    }
    await _requireCleanReset(repository);
  } else if (recorded != null && head != recorded) {
    throw FormatException(
        'HEAD differs from the recorded upstream base. Normal import requires a fresh checkout at that base. '
        'Export changes you want to retain, then use --reset to rebuild from $recorded. '
        'For a different upstream revision, start with a fresh upstream checkout');
  }
  // Published forks can retain commit metadata while losing private refs.
  final imported = (await git(repository, [
    'log',
    '-1',
    '--format=%H',
    '--extended-regexp',
    '--grep=^(Patch-Filename: |Patch-Dir: |Patch-Replace-File:)',
    reset ? recorded! : head
  ]))
      .trim();
  if (imported.isNotEmpty) {
    throw FormatException(reset
        ? 'The recorded upstream base contains imported patch metadata; refusing to use an assembled history as upstream'
        : 'Imported patch history detected. Export changes first and use --reset if the recorded upstream base is available; '
            'otherwise start from a fresh upstream checkout');
  }
}

Future<void> _requireCleanReset(String repository) async {
  final status = await git(repository, [
    'status',
    '--porcelain=v1',
    '--untracked-files=all',
    '--ignore-submodules=none'
  ]);
  if (status.isNotEmpty) {
    throw FormatException(
        'Cannot --reset with uncommitted changes or untracked files. '
        'Commit, export, or move them first; no files have been cleaned');
  }
}

Future<void> _checkIgnoredCollisions(String repository, String head,
    String base, Set<String> destinations) async {
  final ignored = (await git(repository,
          ['ls-files', '--others', '--ignored', '--exclude-standard', '-z']))
      .split('\x00')
      .where((path) => path.isNotEmpty)
      // Git reports ignored nested repositories as directory entries.
      .map((path) =>
          path.endsWith('/') ? path.substring(0, path.length - 1) : path)
      .toSet();
  if (ignored.isEmpty) return;
  final ignoredDirectories = <String>{};
  for (final path in ignored) {
    var directory = p.posix.dirname(path);
    while (directory != '.') {
      ignoredDirectories.add(directory);
      directory = p.posix.dirname(directory);
    }
  }
  final restored = (await git(repository, [
    'diff-tree',
    '--no-commit-id',
    '--no-renames',
    '--name-only',
    '-r',
    '--diff-filter=AT',
    '-z',
    head,
    base
  ]))
      .split('\x00')
      .where((path) => path.isNotEmpty);
  for (final path in {...destinations, ...restored}) {
    var parent = path;
    var collision = ignoredDirectories.contains(path);
    while (parent != '.') {
      collision = collision || ignored.contains(parent);
      parent = p.posix.dirname(parent);
    }
    if (collision) {
      throw FormatException(
          'Ignored local files would be overwritten at $path. Move them before using --reset');
    }
  }
}

Future<void> _validateMail(
    String repository, PatchMail mail, Directory temporary) async {
  if (mail.files.isEmpty)
    throw FormatException('A reset patch must contain file diffs');
  final process = await Process.start('git', [
    '-C',
    repository,
    'mailinfo',
    '${temporary.path}/message',
    '${temporary.path}/diff'
  ]);
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  process.stdin.write(
      [...mail.message, for (final file in mail.files) file.gitDiff].join());
  await process.stdin.close();
  final code = await process.exitCode;
  final metadata = await output;
  final diagnostics = await errors;
  if (code != 0) throw FormatException('Invalid patch mail: $diagnostics');
  final fields = <String, String>{};
  for (final line in const LineSplitter().convert(metadata)) {
    final separator = line.indexOf(': ');
    if (separator > 0)
      fields[line.substring(0, separator)] = line.substring(separator + 2);
  }
  if ((fields['Author'] ?? '').isEmpty || (fields['Email'] ?? '').isEmpty) {
    throw FormatException(
        'Patch mail must contain a usable author name and email');
  }
  await git(repository, [
    'var',
    'GIT_AUTHOR_IDENT'
  ], environment: {
    'GIT_AUTHOR_NAME': fields['Author']!,
    'GIT_AUTHOR_EMAIL': fields['Email']!,
    if (fields['Date']?.isNotEmpty == true) 'GIT_AUTHOR_DATE': fields['Date']!,
  });
}

List<List<String>> splitPatches(String data) {
  final patches = <List<String>>[];
  for (final line in patchLines(data)) {
    if (RegExp(r'^From [0-9a-f]+ ').hasMatch(line)) patches.add([]);
    if (patches.isEmpty) throw FormatException('Expected a Git mail patch');
    patches.last.add(line);
  }
  return patches;
}

String _filename(List<String> patch) {
  for (final line in patch) {
    if (line.startsWith(patchFilenamePrefix)) {
      return line
          .substring(patchFilenamePrefix.length)
          .replaceFirst(RegExp(r'\n$'), '');
    }
  }
  final subjectLine = patch.firstWhere((line) => line.startsWith('Subject: '));
  var subject = subjectLine.substring('Subject: '.length).trimRight();
  if (subject.endsWith('.patch'))
    subject = subject.substring(0, subject.length - 6);
  return '${subject.replaceAll(RegExp(r'[^A-Za-z0-9-]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '').toLowerCase()}.patch';
}

String _joinPatch(List<String> patch) {
  final result = StringBuffer();
  var forceKeepNext = false;
  var sawDiff = false;
  var previousWasBlank = true;
  for (var index = 0; index < patch.length; index++) {
    final line = patch[index];
    final skip = isPatchLocation(line) || line.startsWith(replaceFilePrefix);
    final skipNext = index + 1 < patch.length &&
        (isPatchLocation(patch[index + 1]) ||
            patch[index + 1].startsWith(replaceFilePrefix));
    if (forceKeepNext || !(skip || (skipNext && line.trimRight().isEmpty))) {
      if (!sawDiff && line.startsWith('diff --git ')) {
        if (!previousWasBlank) result.writeln();
        sawDiff = true;
      }
      result.write(line);
      previousWasBlank = line.trimRight().isEmpty;
    }
    forceKeepNext = line.startsWith('Subject: ');
  }
  final contents = result.toString();
  // Binary payloads need their terminating blank line; retain existing text formatting.
  if (contents.contains('\nGIT binary patch\n')) return contents;
  return '${contents.replaceFirst(RegExp(r'\n+$'), '')}\n';
}

Future<void> exportPatches(String repository, String directory,
    {String? patchRange,
    String? manifest,
    bool dryRun = false,
    String? grep,
    bool updateShared = false}) async {
  if (Directory(repository).existsSync() &&
      await _tryExportRepair(repository, directory,
          manifest: manifest,
          patchRange: patchRange,
          grep: grep,
          dryRun: dryRun,
          updateShared: updateShared)) return;
  await _exportPatches(repository, directory,
      patchRange: patchRange,
      manifest: manifest,
      dryRun: dryRun,
      grep: grep,
      updateShared: updateShared);
}

Future<void> _exportPatches(String repository, String directory,
    {String? patchRange,
    String? manifest,
    bool dryRun = false,
    String? grep,
    bool updateShared = false}) async {
  if (!Directory(repository).existsSync()) {
    stderr
        .writeln('Skipping patches in $repository because it does not exist.');
    return;
  }
  final selection = resolveManifest(directory, manifest);
  if (patchRange == null) {
    String count;
    try {
      patchRange =
          (await git(repository, ['rev-parse', '--verify', upstreamHead]))
              .trim();
      count = (await git(repository, ['rev-list', '--count', '$patchRange..']))
          .trim();
    } on ProcessException {
      final description =
          (await git(repository, ['describe', '--tags'])).trim();
      final match = RegExp(r'^(.*)-(\d+)-g[0-9a-f]+$').firstMatch(description);
      patchRange = match?[1] ?? description;
      count = match?[2] ?? '0';
    }
    final abbreviated =
        patchRange.length > 7 ? patchRange.substring(0, 7) : patchRange;
    stderr
        .writeln('Exporting $count patches in $repository since $abbreviated');
  }
  var patches = await _formatPatchSeries(repository, patchRange);
  if (grep != null && grep.isNotEmpty) {
    final total = patches.length;
    final selected = patches
        .where((patch) => patch.any((line) => line.contains(grep)))
        .map(_filename)
        .toSet();
    patches =
        patches.where((patch) => selected.contains(_filename(patch))).toList();
    stderr.writeln('Exporting ${patches.length} of $total patches');
    if (patches.isEmpty) return;
  }
  final exported = <String, String>{};
  String? previousName;
  for (var patch in patches) {
    final mail = PatchMail.parse(patch);
    final replacements = mail.replacementPaths;
    if (replacements.isNotEmpty) {
      patch = await _exportReplacements(repository, mail, replacements);
    }
    patch[0] =
        patch[0].replaceFirst(RegExp(r'^From [0-9a-f]+ '), 'From ${'0' * 40} ');
    final name = _filename(patch);
    validatePatchNames([name], selection);
    if (exported.containsKey(name) && name != previousName) {
      throw FormatException(
          'Nonconsecutive commits use the same patch filename: $name');
    }
    exported[name] = (exported[name] ?? '') + _joinPatch(patch);
    previousName = name;
  }
  writePatchCollection(directory, selection, exported,
      partial: grep != null && grep.isNotEmpty,
      updateShared: updateShared,
      dryRun: dryRun);
}

Future<List<List<String>>> _formatPatchSeries(
    String repository, String range) async {
  // Match the previous tools: ignore user-level attribute overrides during export.
  final data = await git(repository, [
    '-c',
    'core.attributesfile=',
    'format-patch',
    '--keep-subject',
    '--no-stat',
    '--stdout',
    '--no-signature',
    '--always',
    '--full-index',
    range
  ]);
  // format-patch normally omits empty commits. Keep only those that carry
  // replacement intent, since an unchanged image still needs to be exported.
  return splitPatches(data).where((patch) {
    final mail = PatchMail.parse(patch);
    return mail.files.isNotEmpty || mail.replacementPaths.isNotEmpty;
  }).toList();
}

/// Plan the whole series using an isolated index. The checkout and real index
/// stay untouched, and later replacements see the results of earlier commits.
Future<String> _prepareReplacements(String repository, List<PatchMail> mails,
        {required bool threeway}) async =>
    (await _planReplacements(repository, mails, threeway: threeway)).mail;

Future<({String mail, String tree})> _planReplacements(
    String repository, List<PatchMail> mails,
    {required bool threeway, String base = 'HEAD'}) async {
  final temporary = Directory.systemTemp.createTempSync('nest-replacements-');
  final environment = {'GIT_INDEX_FILE': '${temporary.path}/index'};
  final patchFile = File('${temporary.path}/patch');
  final result = StringBuffer();
  try {
    await git(repository, ['read-tree', base], environment: environment);
    for (final mail in mails) {
      final before =
          (await git(repository, ['write-tree'], environment: environment))
              .trim();
      final paths = await _inspectMailFiles(repository, mail, patchFile);
      for (final path in paths) {
        await git(repository, ['update-index', '--force-remove', '--', path],
            environment: environment);
      }
      patchFile
          .writeAsStringSync(mail.files.map((file) => file.gitDiff).join());
      await git(
          repository,
          [
            'apply',
            '--cached',
            '--allow-empty',
            '--whitespace=nowarn',
            if (threeway) '--3way',
            patchFile.path
          ],
          environment: environment);
      final after =
          (await git(repository, ['write-tree'], environment: environment))
              .trim();
      final diff = await git(repository, [..._treeDiffOptions, before, after]);
      result.write(mail.withDiff(diff, replacements: paths).join());
    }
    final tree =
        (await git(repository, ['write-tree'], environment: environment))
            .trim();
    return (mail: result.toString(), tree: tree);
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

/// Validate file syntax and replacement declarations without testing applicability.
Future<List<String>> _inspectMailFiles(
    String repository, PatchMail mail, File patch,
    {Set<String>? destinations}) async {
  final paths = <String>[];
  final counts = <String, int>{};
  for (final file in mail.files) {
    patch.writeAsStringSync(file.gitDiff);
    final path = await _diffDestination(repository, patch);
    counts[path] = (counts[path] ?? 0) + 1;
    destinations?.add(path);
    if (file.replacementMode == null) continue;
    validateReplacementPath(path);
    if (paths.contains(path))
      throw FormatException('Duplicate replacement file: $path');
    paths.add(path);
  }
  for (final path in paths) {
    if (counts[path] != 1) {
      throw FormatException(
          'Replacement has another diff for the same file: $path');
    }
  }
  return paths;
}

Future<String> _diffDestination(String repository, File patch) async {
  final stats = await git(repository, ['apply', '--numstat', '-z', patch.path]);
  final counts = RegExp(r'^(?:\d+|-)\t(?:\d+|-)\t').firstMatch(stats);
  if (counts == null) throw FormatException('Expected one file diff');
  final names = stats.substring(counts.end).split('\x00');
  if (names.length == 2 && names.last.isEmpty) return names.first;
  if (names.length == 4 && names.first.isEmpty && names.last.isEmpty)
    return names[2];
  throw FormatException('Expected one file diff');
}

const _treeDiffOptions = [
  'diff-tree',
  '--no-commit-id',
  '-p',
  '--binary',
  '--full-index',
  '--no-renames',
  '--no-color',
  '--no-ext-diff',
  '--no-textconv',
  '--src-prefix=a/',
  '--dst-prefix=b/'
];

Future<List<String>> _exportReplacements(
    String repository, PatchMail mail, List<String> paths) async {
  final commit = mail.message.first.split(' ')[1];
  final emptyTree = (await git(repository, ['mktree'])).trim();
  final parents =
      (await git(repository, ['rev-list', '--parents', '-n', '1', commit]))
          .trim()
          .split(' ');
  final parent = parents.length > 1 ? parents[1] : emptyTree;
  final result = StringBuffer(await git(repository, [
    ..._treeDiffOptions,
    parent,
    commit,
    '--',
    '.',
    for (final path in paths) ':(exclude,literal)$path'
  ]));
  for (final path in paths) {
    final entry = await git(repository,
        ['--literal-pathspecs', 'ls-tree', '-z', commit, '--', path]);
    if (!RegExp(r'^(100644|100755|120000) blob ').hasMatch(entry)) {
      throw FormatException('Replacement must name a committed file: $path');
    }
    final diff = await git(repository, [
      '--literal-pathspecs',
      ..._treeDiffOptions,
      emptyTree,
      commit,
      '--',
      path
    ]);
    result.write(diff.replaceFirst(
        RegExp(r'^new file mode ', multiLine: true), 'replace file mode '));
  }
  return mail.withDiff(result.toString());
}
