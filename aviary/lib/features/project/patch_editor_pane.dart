import 'dart:io';

import 'package:aviary/infrastructure/code_layout.dart';
import 'package:aviary/infrastructure/patch_files.dart';
import 'package:flutter/material.dart';

class PatchFileEditor extends StatefulWidget {
  const PatchFileEditor({super.key, required this.patchFile});

  final File? patchFile;

  @override
  State<PatchFileEditor> createState() => _PatchFileEditorState();
}

class _PatchFileEditorState extends State<PatchFileEditor> {
  var _patchFileContent = TextSpan(text: "");

  var _patchLines = <TextSpan>[];

  @override
  void initState() {
    super.initState();

    _loadPatchFile();
  }

  @override
  void didUpdateWidget(PatchFileEditor oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.patchFile != oldWidget.patchFile) {
      _loadPatchFile();
    }
  }

  Future<void> _loadPatchFile() async {
    final patchFile = widget.patchFile;
    if (patchFile == null) {
      setState(() {
        _patchFileContent = TextSpan(text: "");
      });
      return;
    }

    final content = await patchFile.readAsString();
    if (widget.patchFile != patchFile) {
      return;
    }

    final patch = Patch.parse(content);

    setState(() {
      _patchLines = PatchStyler.stylePatch(patch);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF160D1C),
      child: Column(
        children: [
          Expanded(child: _buildCodeLines()),
          _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildCodeLines() {
    return CodeLines(codeLines: _patchLines, indentLineColor: indentLineColor, baseTextStyle: baseCodeTextStyle);

    // return ListView.builder(
    //   itemCount: _patchLines.length,
    //   itemBuilder: (context, index) {
    //     return IntrinsicHeight(
    //       child: Row(
    //         crossAxisAlignment: CrossAxisAlignment.stretch,
    //         children: [
    //           SizedBox(
    //             width: 50,
    //             child: Padding(
    //               padding: const EdgeInsets.symmetric(horizontal: 8),
    //               child: Align(
    //                 alignment: Alignment.centerRight,
    //                 child: Text(
    //                   "${index + 1}",
    //                   textAlign: TextAlign.right,
    //                   style: baseCodeTextStyle.apply(color: const Color(0xFF3E484F)),
    //                 ),
    //               ),
    //             ),
    //           ),
    //           Container(width: 1, color: Colors.white.withValues(alpha: 0.05)),
    //           const SizedBox(width: 2),
    //           Expanded(
    //             child: Container(
    //               padding: const EdgeInsets.only(left: 16, top: 4, bottom: 4),
    //               color:
    //                   _patchLines[index].toPlainText().startsWith("+") //
    //                   ? const Color(0xFF09210D)
    //                   : _patchLines[index].toPlainText().startsWith("-")
    //                   ? Colors.red.withValues(alpha: 0.15)
    //                   : Colors.transparent,
    //               child: Align(
    //                 alignment: Alignment.centerLeft,
    //                 child: Text.rich(_patchLines[index], maxLines: 1, overflow: TextOverflow.ellipsis),
    //               ),
    //             ),
    //           ),
    //         ],
    //       ),
    //     );
    //   },
    // );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: const Color(0xFF160D1C),
      child: widget.patchFile != null
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    widget.patchFile!.absolute.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: const Color(0xFF7D5285), fontSize: 11, letterSpacing: 1),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Icon(Icons.open_in_new, size: 16, color: const Color(0xFF7D5285)),
                ),
              ],
            )
          : const SizedBox(),
    );
  }
}
