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

import 'dart:io';

import 'package:path/path.dart' as p;

const channelManifests = [
  '.patches-master',
  '.patches-beta',
  '.patches-stable'
];
const patchDirectoryPrefix = 'Patch-Dir: ';
const patchFilenamePrefix = 'Patch-Filename: ';

/// Split mail without normalizing line endings in diff payloads.
List<String> patchLines(String text) =>
    RegExp(r'[^\n]*\n|[^\n]+$').allMatches(text).map((m) => m[0]!).toList();

bool isPatchLocation(String line) =>
    line.startsWith(patchDirectoryPrefix) ||
    line.startsWith(patchFilenamePrefix);

String resolveManifest(String directory, String? manifest) {
  if (manifest == null) {
    if (channelManifests
        .any((name) => File(p.join(directory, name)).existsSync())) {
      throw FormatException(
          'Select a channel with --channel or a manifest with --manifest');
    }
    manifest = '.patches';
  }
  if (!['.patches', ...channelManifests].contains(manifest)) {
    throw FormatException('Unsupported patch manifest: $manifest');
  }
  return manifest;
}

String patchIdentity(String name) {
  var stem = name.substring(0, name.length - '.patch'.length);
  final adaptation = RegExp(r'_(\d{4}-\d{1,2}-\d{1,2})$').firstMatch(stem);
  if (adaptation != null) {
    final text = adaptation[1]!;
    final date = DateTime.tryParse(text);
    if (date == null ||
        date.year < 1 ||
        date.toIso8601String().substring(0, 10) != text) {
      throw FormatException('Invalid adaptation date: $text');
    }
    stem = stem.substring(0, adaptation.start);
  }
  if (stem.isEmpty) {
    throw FormatException('Patch filename must include a change name: $name');
  }
  return stem;
}

void validatePatchNames(Iterable<String> entries, String manifest) {
  final selected = <String>{};
  final identities = <String>{};
  for (final name in entries) {
    if (name.isEmpty ||
        name != name.trim() ||
        !name.endsWith('.patch') ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains(':') ||
        name == '.patch' ||
        name == '..patch') {
      throw FormatException(
          '$manifest: expected a patch filename in the collection root: "$name"');
    }
    if (!selected.add(name)) {
      throw FormatException('$manifest: duplicate entry: $name');
    }
    final identity = patchIdentity(name);
    if (!identities.add(identity)) {
      throw FormatException('$manifest: multiple variants of $identity');
    }
  }
}

List<String> readManifest(String directory, String manifest,
    {bool required = true}) {
  final path = p.join(directory, manifest);
  if (FileSystemEntity.isLinkSync(path)) {
    throw FormatException('$manifest must be a regular file');
  }
  final file = File(path);
  if (!required && !file.existsSync()) return [];
  final entries = file.readAsLinesSync();
  if (required && entries.isEmpty) {
    throw FormatException('$manifest must list at least one patch');
  }
  validatePatchNames(entries, manifest);
  for (final name in entries) {
    if (FileSystemEntity.isLinkSync(p.join(directory, name))) {
      throw FormatException(
          '$manifest: patch paths cannot contain symlinks: $name');
    }
  }
  return entries;
}

String readPatchCollection(String directory, String manifest) {
  final result = StringBuffer();
  for (final name in readManifest(directory, manifest)) {
    var addedLocation = false;
    for (final line
        in patchLines(File(p.join(directory, name)).readAsStringSync())) {
      if (RegExp(r'^From [0-9a-f]{40}(?:[0-9a-f]{24})? ').hasMatch(line)) {
        addedLocation = false;
      }
      if (!addedLocation &&
          (line.startsWith('diff -') || line.startsWith('---'))) {
        result.writeln('$patchDirectoryPrefix$directory');
        result.writeln('$patchFilenamePrefix$name');
        addedLocation = true;
      }
      result.write(line);
    }
  }
  return result.toString();
}

/// Validate the entire export before writing, preserving other channel selections.
void writePatchCollection(
    String directory, String manifest, Map<String, String> patches,
    {bool partial = false, bool updateShared = false, bool dryRun = false}) {
  final previous = readManifest(directory, manifest, required: false);
  final references = <String>{};
  for (final other in ['.patches', ...channelManifests]) {
    if (other != manifest) {
      references.addAll(readManifest(directory, other, required: false));
    }
  }
  var entries = patches.keys.toList();
  validatePatchNames(entries, manifest);
  if (partial) {
    final replacements = {
      for (final name in entries) patchIdentity(name): name
    };
    entries = [
      for (final name in previous)
        replacements.remove(patchIdentity(name)) ?? name,
      ...replacements.values
    ];
  }
  validatePatchNames(entries, manifest);
  if (entries.isEmpty) {
    throw FormatException('$manifest: export would leave an empty collection');
  }
  final changed = <String, String>{};
  for (final entry in patches.entries) {
    final target = File(p.join(directory, entry.key));
    if (FileSystemEntity.isLinkSync(target.path)) {
      throw FormatException(
          'Patch paths cannot contain symlinks: ${entry.key}');
    }
    if (!target.existsSync() || target.readAsStringSync() != entry.value) {
      if (references.contains(entry.key) &&
          target.existsSync() &&
          !updateShared) {
        throw FormatException(
            '${entry.key} is shared with another manifest; create a dated adaptation '
            'or use --update-shared to change it for all consumers');
      }
      changed[entry.key] = entry.value;
    }
  }
  final manifestContents = entries.map((name) => '$name\n').join();
  final manifestFile = File(p.join(directory, manifest));
  if (!manifestFile.existsSync() ||
      manifestFile.readAsStringSync() != manifestContents) {
    changed[manifest] = manifestContents;
  }
  final removed =
      previous.toSet().difference(entries.toSet()).difference(references);
  if (dryRun) {
    if (changed.isNotEmpty || removed.isNotEmpty) {
      throw FormatException('Export would change: ${[
        ...changed.keys,
        ...(removed.toList()..sort())
      ].join(', ')}');
    }
    return;
  }
  Directory(directory).createSync(recursive: true);
  for (final entry in changed.entries) {
    _writeFile(File(p.join(directory, entry.key)), entry.value);
  }
  for (final name in removed) {
    final file = File(p.join(directory, name));
    if (file.existsSync()) file.deleteSync();
  }
}

void _writeFile(File target, String contents) {
  // A complete temporary file prevents interruption from truncating the target.
  // Keep the temporary file on the same filesystem for atomic rename.
  final sibling = target.parent.createTempSync('.patch-export-');
  final temporary = File(p.join(sibling.path, 'contents'));
  try {
    temporary.writeAsStringSync(contents, flush: true);
    if (!Platform.isWindows) {
      final mode = target.existsSync() ? target.statSync().mode & 0x1ff : 0x1a4;
      final result =
          Process.runSync('chmod', [mode.toRadixString(8), temporary.path]);
      if (result.exitCode != 0) {
        throw FileSystemException(
            'Cannot preserve file permissions: ${result.stderr}', target.path);
      }
    }
    temporary.renameSync(target.path);
  } finally {
    sibling.deleteSync(recursive: true);
  }
}
