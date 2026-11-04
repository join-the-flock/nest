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

import 'patch_collection.dart';
import 'patch_protocol.dart';

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
    {bool threeway = false}) async {
  final mails = splitPatches(patchData).map(PatchMail.parse).toList();
  for (final mail in mails) {
    if (mail.replacementPaths.isNotEmpty) {
      throw FormatException(
          'Patch-Replace-File is reserved import metadata; use replace file mode');
    }
  }
  final extended = mails
      .any((mail) => mail.files.any((file) => file.replacementMode != null));
  if (extended) {
    patchData =
        await _prepareReplacements(repository, mails, threeway: threeway);
  }
  await git(repository, ['update-ref', upstreamHead, 'HEAD']);
  final arguments = [
    '-C',
    repository,
    '-c',
    'commit.gpgsign=false',
    'am',
    if (threeway) '--3way',
    if (extended) '--empty=keep',
    if (extended) '--whitespace=nowarn',
    '--keep-cr'
  ];
  final process = await Process.start('git', arguments);
  final output = stdout.addStream(process.stdout);
  final errors = stderr.addStream(process.stderr);
  process.stdin.add(utf8.encode(patchData));
  await process.stdin.close();
  final code = await process.exitCode;
  await Future.wait([output, errors]);
  if (code != 0) {
    throw ProcessException('git', arguments, 'Patch import failed', code);
  }
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
    patchRange
  ]);
  // format-patch normally omits empty commits. Keep only those that carry
  // replacement intent, since an unchanged image still needs to be exported.
  var patches = splitPatches(data).where((patch) {
    final mail = PatchMail.parse(patch);
    return mail.files.isNotEmpty || mail.replacementPaths.isNotEmpty;
  }).toList();
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

/// Plan the whole series using an isolated index. The checkout and real index
/// stay untouched, and later replacements see the results of earlier commits.
Future<String> _prepareReplacements(String repository, List<PatchMail> mails,
    {required bool threeway}) async {
  final temporary = Directory.systemTemp.createTempSync('nest-replacements-');
  final environment = {'GIT_INDEX_FILE': '${temporary.path}/index'};
  final patchFile = File('${temporary.path}/patch');
  final result = StringBuffer();
  try {
    await git(repository, ['read-tree', 'HEAD'], environment: environment);
    for (final mail in mails) {
      final before =
          (await git(repository, ['write-tree'], environment: environment))
              .trim();
      final paths = <String>[];
      final destinations = <String>[];
      for (final file in mail.files) {
        patchFile.writeAsStringSync(file.gitDiff);
        final path = await _diffDestination(repository, patchFile);
        destinations.add(path);
        if (file.replacementMode == null) continue;
        validateReplacementPath(path);
        if (paths.contains(path)) {
          throw FormatException('Duplicate replacement file: $path');
        }
        paths.add(path);
      }
      for (final path in paths) {
        if (destinations.where((destination) => destination == path).length !=
            1) {
          throw FormatException(
              'Replacement has another diff for the same file: $path');
        }
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
    return result.toString();
  } finally {
    temporary.deleteSync(recursive: true);
  }
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
