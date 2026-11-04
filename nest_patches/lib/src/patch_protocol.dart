import 'patch_collection.dart';

/// Internal commit metadata, converted back to file headers on export.
const replaceFilePrefix = 'Patch-Replace-File: ';

/// A Git mail message followed by its file diffs, with payload bytes preserved.
class PatchMail {
  PatchMail(this.message, this.files);

  factory PatchMail.parse(List<String> lines) {
    final message = <String>[];
    final files = <PatchFile>[];
    List<String>? current;
    for (final line in lines) {
      if (line.startsWith('diff --git ')) {
        current = [];
        files.add(PatchFile(current));
      }
      (current ?? message).add(line);
    }
    return PatchMail(message, files);
  }

  final List<String> message;
  final List<PatchFile> files;

  /// Only inspect the description, never diff payloads or diff statistics.
  List<String> get replacementPaths {
    final paths = <String>[];
    for (final line in message) {
      if (line.trimRight() == '---') break;
      if (!line.startsWith('Patch-Replace-File:')) continue;
      if (!line.startsWith(replaceFilePrefix)) {
        throw FormatException('Expected $replaceFilePrefix<path>');
      }
      final path = line
          .substring(replaceFilePrefix.length)
          .replaceFirst(RegExp(r'\n$'), '');
      validateReplacementPath(path);
      if (paths.contains(path)) {
        throw FormatException('Duplicate replacement declaration: $path');
      }
      paths.add(path);
    }
    return paths;
  }

  /// Keep mail headers and the description, and replace only the diff area.
  List<String> withDiff(String diff, {List<String> replacements = const []}) {
    final prefix = message.toList();
    var insertion = prefix.indexWhere((line) => line.trimRight() == '---');
    if (insertion < 0) insertion = prefix.length;
    if (replacements.isNotEmpty) {
      prefix.insertAll(insertion, [
        if (insertion > 0 && prefix[insertion - 1].trim().isNotEmpty) '\n',
        for (final path in replacements) '$replaceFilePrefix$path\n',
        '\n',
      ]);
    }
    return [...prefix, ...patchLines(diff)];
  }
}

/// A file diff with an optional unconditional replacement extended header.
class PatchFile {
  PatchFile(this.lines);

  final List<String> lines;

  List<String> get _headers => lines
      .skip(1)
      .takeWhile((line) =>
          !line.startsWith('--- ') &&
          !line.startsWith('+++ ') &&
          !line.startsWith('@@') &&
          !line.startsWith('GIT binary patch'))
      .toList();

  String? get replacementMode {
    final headers = _headers;
    final declarations =
        headers.where((line) => line.startsWith('replace file ')).toList();
    if (declarations.isEmpty) return null;
    if (declarations.length != 1) {
      throw FormatException(
          'A file diff must have one replace file mode header');
    }
    final match = RegExp(r'^replace file mode (100644|100755|120000)\n?$')
        .firstMatch(declarations.single);
    if (match == null) {
      throw FormatException(
          'Unsupported replacement mode: ${declarations.single.trimRight()}');
    }
    if (headers.any((line) =>
        line.startsWith('new file mode ') ||
        line.startsWith('deleted file mode ') ||
        line.startsWith('old mode ') ||
        line.startsWith('new mode ') ||
        line.startsWith('rename ') ||
        line.startsWith('copy ') ||
        line.startsWith('similarity ') ||
        line.startsWith('dissimilarity '))) {
      throw FormatException(
          'Replacement cannot also add, delete, rename, copy, or change mode');
    }
    for (final header in headers.where((line) => line.startsWith('index '))) {
      if (!RegExp(r'^index 0+\.\.[0-9a-f]+(?: [0-7]{6})?\n?$')
          .hasMatch(header)) {
        throw FormatException('Replacement must not depend on an old blob');
      }
    }
    if (lines
        .any((line) => line.startsWith('--- ') && line != '--- /dev/null\n')) {
      throw FormatException(
          'Replacement must contain a complete new-file diff');
    }
    final hunks = lines.where((line) => line.startsWith('@@')).toList();
    if (hunks.isEmpty &&
        !lines.contains('GIT binary patch\n') &&
        lines.any((line) => line.startsWith('--- ') || line.startsWith('+'))) {
      throw FormatException('Replacement text image requires an addition hunk');
    }
    if (hunks.isNotEmpty) {
      final hunk =
          RegExp(r'^@@ -0,0 \+1(?:,(\d+))? @@\n?$').firstMatch(hunks.first);
      if (hunks.length != 1 || hunk == null) {
        throw FormatException(
            'Replacement must contain one complete addition hunk');
      }
      final count = int.parse(hunk[1] ?? '1');
      final body = lines.skip(lines.indexOf(hunks.first) + 1).toList();
      final additions = body.takeWhile((line) => line.startsWith('+')).length;
      if (additions != count ||
          body.skip(additions).any((line) =>
              line.startsWith('+') ||
              line.startsWith('-') && !line.startsWith('-- '))) {
        throw FormatException(
            'Replacement image does not match its hunk length');
      }
    }
    return match[1];
  }

  /// Git can validate and decode the complete image using its new-file syntax.
  String get gitDiff {
    final mode = replacementMode;
    return lines
        .map((line) => mode != null && line.startsWith('replace file mode ')
            ? 'new file mode $mode\n'
            : line)
        .join();
  }
}

/// Paths in replacement metadata are literal repository-relative file paths.
void validateReplacementPath(String path) {
  if (path.isEmpty ||
      path != path.trim() ||
      path.startsWith('/') ||
      path.contains('\\') ||
      path.contains(':') ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(path) ||
      path.split('/').any((part) =>
          part.isEmpty ||
          part == '.' ||
          part == '..' ||
          part.toLowerCase() == '.git')) {
    throw FormatException('Invalid replacement path: $path');
  }
}
