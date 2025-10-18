import 'package:flutter/material.dart';

abstract class PatchStyler {
  static List<TextSpan> stylePatch(Patch patch) {
    final lines = <TextSpan>[];

    // File header lines
    for (final line in patch.header) {
      lines.add(
        TextSpan(
          text: line,
          style: baseCodeTextStyle.apply(color: Colors.blueGrey).merge(TextStyle(fontWeight: FontWeight.bold)),
        ),
      );
    }

    // Each block (hunk)
    for (final block in patch.blocks) {
      // Block header (lines starting with @@)
      for (final headerLine in block.blockHeader) {
        lines.add(
          TextSpan(
            text: headerLine,
            style: baseCodeTextStyle.apply(color: Colors.blue).merge(TextStyle(fontWeight: FontWeight.bold)),
          ),
        );
      }

      // Block entries (changes, context, special)
      for (final entry in block.entries) {
        lines.add(_createPatchEntrySpan(entry));
      }
    }

    return lines;
  }

  static TextSpan _createPatchEntrySpan(PatchEntry entry) {
    switch (entry.type) {
      case PatchEntryType.added:
        return TextSpan(
          text: entry.text,
          style: baseCodeTextStyle.apply(color: const Color(0xFF299B3C)),
        );
      case PatchEntryType.removed:
        return TextSpan(
          text: entry.text,
          style: baseCodeTextStyle.apply(color: Colors.red),
        );
      case PatchEntryType.context:
        return TextSpan(
          text: entry.text,
          style: baseCodeTextStyle.apply(color: Colors.grey),
        );
      case PatchEntryType.special:
        return TextSpan(
          text: entry.text,
          style: baseCodeTextStyle.apply(color: Colors.deepPurple),
        );
    }
  }
}

final baseCodeTextStyle = const TextStyle(fontFamily: "fira-mono", fontSize: 16, fontWeight: FontWeight.normal);

class Patch {
  static Patch parse(String content) {
    final lines = content.split('\n');

    final header = <String>[];
    final blocks = <PatchBlock>[];

    var currentHeader = <String>[];
    var currentEntries = <PatchEntry>[];
    bool inHunk = false;

    for (final line in lines) {
      if (line.startsWith('@@')) {
        if (inHunk) {
          // finish previous block
          blocks.add(PatchBlock(currentHeader, currentEntries));
          currentHeader = [];
          currentEntries = [];
        } else {
          // everything before first hunk = file header
          header.addAll(currentEntries.map((e) => e.text));
          currentEntries = [];
          inHunk = true;
        }
        currentHeader.add(line);
      } else {
        if (inHunk) {
          currentEntries.add(_makeEntry(line));
        } else {
          currentEntries.add(PatchEntry(PatchEntryType.context, line));
        }
      }
    }

    if (inHunk) {
      blocks.add(PatchBlock(currentHeader, currentEntries));
    } else if (currentEntries.isNotEmpty) {
      // only header, no hunks
      header.addAll(currentEntries.map((e) => e.text));
    }

    return Patch(header, blocks);
  }

  static bool _isSpecialMessage(String line) {
    return line.startsWith('\\ No newline at end of file') ||
        line.startsWith('Binary files ') ||
        line.startsWith('GIT binary patch') ||
        line.startsWith('old mode ') ||
        line.startsWith('new mode ') ||
        line.startsWith('deleted file mode ') ||
        line.startsWith('new file mode ') ||
        line.startsWith('rename from ') ||
        line.startsWith('rename to ') ||
        line.startsWith('copy from ') ||
        line.startsWith('copy to ') ||
        line.startsWith('index ');
  }

  static PatchEntry _makeEntry(String line) {
    if (_isSpecialMessage(line)) {
      return PatchEntry(PatchEntryType.special, line);
    } else if (line.startsWith('+')) {
      return PatchEntry(PatchEntryType.added, line);
    } else if (line.startsWith('-')) {
      return PatchEntry(PatchEntryType.removed, line);
    } else if (line.startsWith(' ')) {
      return PatchEntry(PatchEntryType.context, line);
    } else {
      return PatchEntry(PatchEntryType.special, line); // fallback
    }
  }

  const Patch(this.header, this.blocks);

  final List<String> header;
  final List<PatchBlock> blocks;
}

class PatchBlock {
  const PatchBlock(this.blockHeader, this.entries);

  final List<String> blockHeader;
  final List<PatchEntry> entries;
}

class PatchEntry {
  const PatchEntry(this.type, this.text);

  final PatchEntryType type;
  final String text;
}

enum PatchEntryType {
  added, // line starts with "+"
  removed, // line starts with "-"
  context, // line starts with " "
  special, // Git special message
}
