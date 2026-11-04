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

const upstreamHead = 'refs/patches/upstream-head';

Future<String> git(String repository, List<String> arguments) async {
  final result = await Process.run('git', ['-C', repository, ...arguments]);
  if (result.exitCode != 0) {
    throw ProcessException('git', ['-C', repository, ...arguments],
        '${result.stdout}${result.stderr}', result.exitCode);
  }
  return result.stdout as String;
}

Future<void> importPatches(String repository, String patchData,
    {bool threeway = false}) async {
  await git(repository, ['update-ref', upstreamHead, 'HEAD']);
  final arguments = [
    '-C',
    repository,
    '-c',
    'commit.gpgsign=false',
    'am',
    if (threeway) '--3way',
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
  for (var index = 0; index < patch.length; index++) {
    final line = patch[index];
    final skip = isPatchLocation(line);
    final skipNext =
        index + 1 < patch.length && isPatchLocation(patch[index + 1]);
    if (forceKeepNext || !(skip || (skipNext && line.trimRight().isEmpty))) {
      result.write(line);
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
    '--zero-commit',
    '--full-index',
    patchRange
  ]);
  var patches = splitPatches(data);
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
  for (final patch in patches) {
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
