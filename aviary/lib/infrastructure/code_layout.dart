import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:super_editor/super_editor.dart';

// TODO: Define and implement a CodeLinesLayout, similar to CodeLineLayout, but
//       for the whole file.
// TODO: Refactor CodeLines to display in a ContentLayers widget.

/// Widget that displays all the lines of source within a given file or sample.
class CodeLines extends StatefulWidget {
  const CodeLines({super.key, required this.codeLines, required this.indentLineColor, required this.baseTextStyle});

  /// All lines of source code, with syntax highlighting already applied.
  final List<TextSpan> codeLines;

  /// The color of little lines that appear on the upstream side of the code in the
  /// indentation area.
  final Color indentLineColor;

  /// The base text style, applied beneath the styles in [code], and also applied to the indent line spacing.
  final TextStyle baseTextStyle;

  @override
  State<CodeLines> createState() => _CodeLinesState();
}

class _CodeLinesState extends State<CodeLines> implements CodeLinesLayout {
  final _lineKeys = <int, GlobalKey>{};

  @override
  CodeRange? findWordBoundaryAtGlobalOffset(Offset globalOffset) {
    final line = _findLineLayoutAtGlobalOffset(globalOffset);
    if (line == null) {
      return null;
    }

    return line.findWordBoundaryAtGlobalOffset(globalOffset);
  }

  @override
  CodeRange? findWordBoundaryAtLocalOffset(Offset localOffset) {
    final globalOffset = (context.findRenderObject() as RenderBox).localToGlobal(localOffset);
    return findWordBoundaryAtGlobalOffset(globalOffset);
  }

  @override
  CodePosition findCodePositionNearestGlobalOffset(Offset globalOffset) {
    for (int lineIndex = 0; lineIndex < widget.codeLines.length; lineIndex += 1) {
      final lineLayout = _lineKeys[lineIndex]!.asCodeLine;
      if (!lineLayout.containsGlobalYValue(globalOffset.dy)) {
        continue;
      }

      return lineLayout.findCodePositionNearestGlobalOffset(globalOffset);
    }

    return const CodePosition(0, 0);
  }

  @override
  CodePosition findCodePositionNearestLocalOffset(Offset localOffset) {
    final globalOffset = (context.findRenderObject() as RenderBox).localToGlobal(localOffset);
    return findCodePositionNearestGlobalOffset(globalOffset);
  }

  @override
  List<TextBox> getSelectionBoxesForCodeRange(CodeRange codeRange) {
    final boxes = <TextBox>[];

    // Add the boxes for the first selected line, which may start at the middle of the line.
    final firstCodeLine = _lineKeys[codeRange.start.line]!.asCodeLine;
    final firstCodeLineBoxes = firstCodeLine.getBoxesForSelection(
      TextSelection(
        baseOffset: codeRange.start.characterOffset,
        extentOffset: codeRange.start.line == codeRange.end.line
            ? codeRange.end.characterOffset
            : widget.codeLines.first.toPlainText().length,
      ),
    );
    boxes.addAll(_mapCodeLineTextBoxesToLayoutTextBoxes(codeRange.start.line, firstCodeLineBoxes));

    // Add the boxes for the lines between the first and the last, which are fully selected.
    for (int lineIndex = codeRange.start.line + 1; lineIndex < codeRange.end.line - 1; lineIndex += 1) {
      final codeLine = _lineKeys[lineIndex]!.asCodeLine;
      final codeLineBoxes = codeLine.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: widget.codeLines[lineIndex].toPlainText().length),
      );
      boxes.addAll(_mapCodeLineTextBoxesToLayoutTextBoxes(lineIndex, codeLineBoxes));
    }

    // Add the boxes for the last selected line, which may end at the middle of the line.
    if (codeRange.start.line != codeRange.end.line) {
      final lastCodeLine = _lineKeys[codeRange.end.line]!.asCodeLine;
      final lastCodeLineBoxes = lastCodeLine.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: codeRange.end.characterOffset),
      );
      boxes.addAll(_mapCodeLineTextBoxesToLayoutTextBoxes(codeRange.end.line, lastCodeLineBoxes));
    }

    return boxes;
  }

  List<TextBox> _mapCodeLineTextBoxesToLayoutTextBoxes(int lineIndex, List<TextBox> boxes) {
    final layoutRenderBox = context.findRenderObject() as RenderBox;
    final codeLineRenderBox = _lineKeys[lineIndex]!.currentContext!.findRenderObject() as RenderBox;

    return boxes.map((textBox) {
      final topLeft = layoutRenderBox.globalToLocal(codeLineRenderBox.localToGlobal(Offset(textBox.left, textBox.top)));

      final bottomRight = layoutRenderBox.globalToLocal(
        codeLineRenderBox.localToGlobal(Offset(textBox.right, textBox.bottom)),
      );

      return TextBox.fromLTRBD(topLeft.dx, topLeft.dy, bottomRight.dx, bottomRight.dy, TextDirection.ltr);
    }).toList();
  }

  CodeLineLayout _findLineLayoutNearestGlobalOffset(Offset globalOffset) {
    // First, check if the offset is above/below all lines and return
    // the nearest.
    final linesBox = context.findRenderObject() as RenderBox;
    final linesTopLeft = linesBox.localToGlobal(Offset.zero);
    if (globalOffset.dy < linesTopLeft.dy) {
      return _lineKeys[0]!.asCodeLine;
    }
    if (globalOffset.dy > linesTopLeft.dy + linesBox.size.height) {
      return _lineKeys[_lineKeys.length]!.asCodeLine;
    }

    // The offset is somewhere within the lines. Find the line that
    // contains the offset.
    for (int lineIndex in _lineKeys.keys) {
      final lineLayout = _lineKeys[lineIndex]!.asCodeLine;
      if (!lineLayout.containsGlobalYValue(globalOffset.dy)) {
        continue;
      }

      return lineLayout;
    }

    throw Exception("Tried to find the nearest code line to global offset ($globalOffset) but didn't find one.");
  }

  CodeLineLayout? _findLineLayoutAtGlobalOffset(Offset globalOffset) {
    for (int lineIndex = 0; lineIndex < widget.codeLines.length; lineIndex += 1) {
      final lineLayout = _lineKeys[lineIndex]!.asCodeLine;
      if (!lineLayout.containsGlobalYValue(globalOffset.dy)) {
        continue;
      }

      return lineLayout;
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.text,
      child: widget.codeLines.isNotEmpty
          ? CodeScroller(
              delegate: TwoDimensionalChildBuilderDelegate(
                maxXIndex: 1,
                maxYIndex: widget.codeLines.length - 1,
                builder: (context, vicinity) {
                  if (vicinity.xIndex == 0) {
                    return _buildLineIndicator(vicinity.yIndex);
                  }

                  return _buildCodeLine(vicinity.yIndex);
                },
              ),
            )
          : const SizedBox(),
    );
  }

  Widget _buildLineIndicator(int lineIndex) {
    return Container(
      margin: const EdgeInsets.only(right: 4),
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: lineColor)),
      ),
      padding: const EdgeInsets.only(right: 20),
      child: Text(
        " ${lineIndex + 1}",
        textAlign: TextAlign.right,
        style: widget.baseTextStyle.copyWith(color: Colors.white.withValues(alpha: 0.3)),
      ),
    );
  }

  Widget _buildCodeLine(int lineIndex) {
    _lineKeys[lineIndex] ??= GlobalKey(debugLabel: "Code line: $lineIndex");
    final key = _lineKeys[lineIndex];

    return CodeLine(
      key: key,
      lineNumber: lineIndex,
      code: widget.codeLines[lineIndex],
      indentLineColor: widget.indentLineColor,
      baseTextStyle: widget.baseTextStyle,
    );
  }
}

ContentLayerWidget buildCaretOverlay(BuildContext context) {
  return const CodeCaretOverlay();
}

class CodeCaretOverlay extends ContentLayerStatelessWidget {
  const CodeCaretOverlay({super.key});

  @override
  Widget doBuild(BuildContext context, Element? contentElement, RenderObject? contentLayout) {
    // TODO: implement doBuild
    throw UnimplementedError();
  }
}

extension CodeLinesLayoutFromContext on GlobalKey {
  /// Assumes this [GlobalKey] is attached to a [CodeLines] widget, and returns
  /// the [CodeLinesLayout] for the code layout.
  ///
  /// This method is a verbosity reduction for repeated access of code layout.
  CodeLinesLayout get asCodeLines => currentState as CodeLinesLayout;
}

abstract interface class CodeLinesLayout {
  /// Returns the bounds that surround the word that appears at the given
  /// [globalOffset].
  CodeRange? findWordBoundaryAtGlobalOffset(Offset globalOffset);

  /// Returns the bounds that surround the word that appears at the given
  /// [localOffset].
  CodeRange? findWordBoundaryAtLocalOffset(Offset localOffset);

  /// Returns the [CodePosition] nearest to the given [globalOffset].
  CodePosition findCodePositionNearestGlobalOffset(Offset globalOffset);

  /// Returns the [CodePosition] nearest to the given [localOffset].
  CodePosition findCodePositionNearestLocalOffset(Offset localOffset);

  /// Returns a list of [TextBox]es that bound the content selected in the given [codeRange],
  /// in local coordinates.
  ///
  /// See also:
  ///
  ///  * [RenderParagraph.getBoxesForSelection].
  List<TextBox> getSelectionBoxesForCodeRange(CodeRange codeRange);
}

/// Widget that displays a single line of code text.
class CodeLine extends StatefulWidget {
  const CodeLine({
    super.key,
    required this.lineNumber,
    required this.code,
    required this.indentLineColor,
    required this.baseTextStyle,
  });

  /// Line number for this line within its overall source file, starting at zero.
  final int lineNumber;

  /// The styled code to display in this line.
  final TextSpan code;

  /// The color of little lines that appear on the upstream side of the code in the
  /// indentation area.
  final Color indentLineColor;

  /// The base text style, applied beneath the styles in [code], and also applied to the indent line spacing.
  final TextStyle baseTextStyle;

  @override
  State<CodeLine> createState() => _CodeLineState();
}

class _CodeLineState extends State<CodeLine> implements CodeLineLayout {
  final _codeTextKey = GlobalKey();

  @override
  int get lineNumber => widget.lineNumber;

  @override
  bool containsGlobalOffset(Offset globalOffset) {
    final myBox = context.findRenderObject() as RenderBox;
    final myOffset = myBox.localToGlobal(Offset.zero);
    final myRect = myOffset & myBox.size;
    return myRect.contains(globalOffset);
  }

  @override
  bool containsGlobalYValue(double y) {
    final myBox = context.findRenderObject() as RenderBox;
    final myOffset = myBox.localToGlobal(Offset.zero);
    final myRect = myOffset & myBox.size;

    if (widget.lineNumber == 100) {
      print("I'm line 100 and my global origin is: ${myBox.localToGlobal(Offset.zero)}");
    }
    if (myRect.top <= y && y <= myRect.bottom) {
      print("I'm line ${widget.lineNumber} and I contain y: $y");
    }

    return myRect.top <= y && y <= myRect.bottom;
  }

  @override
  CodeRange? findWordBoundaryAtGlobalOffset(Offset globalOffset) {
    final localOffset = (context.findRenderObject() as RenderBox).globalToLocal(globalOffset);
    return findWordBoundaryAtLocalOffset(localOffset);
  }

  @override
  CodeRange? findWordBoundaryAtLocalOffset(Offset localOffset) {
    final codeLineBox = context.findRenderObject() as RenderBox;
    final localRect = Offset.zero & codeLineBox.size;
    if (!localRect.contains(localOffset)) {
      return null;
    }

    final renderParagraph = _renderParagraph;
    final paragraphLocalOffset = renderParagraph.globalToLocal(localOffset, ancestor: codeLineBox);
    //print("Local offset: $paragraphLocalOffset");
    final textPosition = renderParagraph.getPositionForOffset(paragraphLocalOffset);
    //print("Text position: $textPosition");
    final wordRange = renderParagraph.getWordBoundary(textPosition);
    //print("Word range: $wordRange");
    //ðprint("Word: '${renderParagraph.text.toPlainText().substring(wordRange.start, wordRange.end)}'");
    return CodeRange(CodePosition(widget.lineNumber, wordRange.start), CodePosition(widget.lineNumber, wordRange.end));
  }

  @override
  CodePosition findCodePositionNearestGlobalOffset(Offset globalOffset) {
    final localOffset = (_codeTextKey.currentContext!.findRenderObject() as RenderBox).globalToLocal(globalOffset);
    return findCodePositionNearestLocalOffset(localOffset);
  }

  @override
  CodePosition findCodePositionNearestLocalOffset(Offset localOffset) {
    final renderParagraph = _renderParagraph;
    final textPosition = renderParagraph.getPositionForOffset(localOffset);
    return CodePosition(widget.lineNumber, textPosition.offset);
  }

  @override
  List<TextBox> getBoxesForSelection(TextSelection selection) {
    final boxes = _renderParagraph.getBoxesForSelection(
      selection,
      boxHeightStyle: BoxHeightStyle.max,
      boxWidthStyle: BoxWidthStyle.max,
    );

    final renderBox = context.findRenderObject() as RenderBox;
    return boxes.map((textBox) {
      final topLeft = renderBox.globalToLocal(_renderParagraph.localToGlobal(Offset(textBox.left, textBox.top)));
      final bottomRight = renderBox.globalToLocal(
        _renderParagraph.localToGlobal(Offset(textBox.right, textBox.bottom)),
      );

      return TextBox.fromLTRBD(topLeft.dx, topLeft.dy, bottomRight.dx, bottomRight.dy, TextDirection.ltr);
    }).toList();
  }

  RenderParagraph get _renderParagraph => _codeTextKey.currentContext!.findRenderObject() as RenderParagraph;

  @override
  Widget build(BuildContext context) {
    final buffer = StringBuffer();
    widget.code.computeToPlainText(buffer);
    final contentText = buffer.toString();

    final leadingSpaceMatcher = RegExp(r'\s+');
    final leadingSpaceMatch = leadingSpaceMatcher.matchAsPrefix(contentText);
    int tabCount = 0;
    if (leadingSpaceMatch != null) {
      // -1 because the very first indentation line is the same as the divider between lines and code.
      tabCount = (leadingSpaceMatch.end ~/ 2) - 1;
    }

    return Row(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(width: 2),
            for (int i = 0; i < tabCount; i += 1) //
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(right: BorderSide(color: widget.indentLineColor, width: 1)),
                ),
                child: Text("  ", style: widget.baseTextStyle),
              ),
          ],
        ),
        Text.rich(key: _codeTextKey, widget.code, style: widget.baseTextStyle),
      ],
    );
  }
}

class CodeScroller extends TwoDimensionalScrollView {
  const CodeScroller({
    super.key,
    super.primary,
    super.mainAxis = Axis.vertical,
    super.verticalDetails = const ScrollableDetails.vertical(physics: ClampingScrollPhysics()),
    super.horizontalDetails = const ScrollableDetails.horizontal(physics: ClampingScrollPhysics()),
    required TwoDimensionalChildBuilderDelegate delegate,
    super.cacheExtent,
    super.diagonalDragBehavior = DiagonalDragBehavior.free,
    super.dragStartBehavior = DragStartBehavior.start,
    super.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
    super.clipBehavior = Clip.hardEdge,
  }) : super(delegate: delegate);

  @override
  Widget buildViewport(BuildContext context, ViewportOffset verticalOffset, ViewportOffset horizontalOffset) {
    return CodeScrollerViewport(
      horizontalOffset: horizontalOffset,
      horizontalAxisDirection: horizontalDetails.direction,
      verticalOffset: verticalOffset,
      verticalAxisDirection: verticalDetails.direction,
      mainAxis: mainAxis,
      delegate: delegate as TwoDimensionalChildBuilderDelegate,
      cacheExtent: cacheExtent,
      clipBehavior: clipBehavior,
    );
  }
}

class CodeScrollerViewport extends TwoDimensionalViewport {
  const CodeScrollerViewport({
    super.key,
    required super.verticalOffset,
    required super.verticalAxisDirection,
    required super.horizontalOffset,
    required super.horizontalAxisDirection,
    required TwoDimensionalChildBuilderDelegate super.delegate,
    required super.mainAxis,
    super.cacheExtent,
    super.clipBehavior = Clip.hardEdge,
  });

  @override
  RenderTwoDimensionalViewport createRenderObject(BuildContext context) {
    return RenderCodeScrollerViewport(
      horizontalOffset: horizontalOffset,
      horizontalAxisDirection: horizontalAxisDirection,
      verticalOffset: verticalOffset,
      verticalAxisDirection: verticalAxisDirection,
      mainAxis: mainAxis,
      delegate: delegate as TwoDimensionalChildBuilderDelegate,
      childManager: context as TwoDimensionalChildManager,
      cacheExtent: cacheExtent,
      clipBehavior: clipBehavior,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderCodeScrollerViewport renderObject) {
    renderObject
      ..horizontalOffset = horizontalOffset
      ..horizontalAxisDirection = horizontalAxisDirection
      ..verticalOffset = verticalOffset
      ..verticalAxisDirection = verticalAxisDirection
      ..mainAxis = mainAxis
      ..delegate = delegate
      ..cacheExtent = cacheExtent
      ..clipBehavior = clipBehavior;
  }
}

class RenderCodeScrollerViewport extends RenderTwoDimensionalViewport {
  RenderCodeScrollerViewport({
    required super.horizontalOffset,
    required super.horizontalAxisDirection,
    required super.verticalOffset,
    required super.verticalAxisDirection,
    required TwoDimensionalChildBuilderDelegate delegate,
    required super.mainAxis,
    required super.childManager,
    super.cacheExtent,
    super.clipBehavior = Clip.hardEdge,
  }) : super(delegate: delegate);

  final LayerHandle<ClipRectLayer> _clipRectLayer = LayerHandle<ClipRectLayer>();

  late ChildVicinity _leadingVicinity;
  late ChildVicinity _trailingVicinity;

  @override
  void dispose() {
    _clipRectLayer.layer = null;
    super.dispose();
  }

  @override
  void layoutChildSequence() {
    final builderDelegate = delegate as TwoDimensionalChildBuilderDelegate;

    // We only have two columns, the line indicator, and the line itself.
    assert(builderDelegate.maxXIndex == 1);

    final verticalPixels = verticalOffset.pixels;
    final viewportHeight = viewportDimension.height + cacheExtent;
    final maxRowIndex = builderDelegate.maxYIndex!;

    // We need to layout all children to compute the maximum line width
    // and maximum indicator width.
    //
    // To do this, we need to call buildOrObtainChildFor for each vicinity. Calling
    // buildOrObtainChildFor more than once for the same vinicity throws an
    // assertion error.
    //
    // Cache the children to avoid that.
    final childrenCache = <ChildVicinity, RenderBox>{};

    // The line height is computed when the first line is laid out.
    double lineHeight = 0;

    double maxLineIndicatorWidth = 0;
    double maxLineWidth = 0;
    for (int i = 0; i <= maxRowIndex; i++) {
      // Compute the maximum width of the line indicator.
      // We will layout all of them after with the same width.
      final lineIndicatorVicinity = ChildVicinity(xIndex: 0, yIndex: i);
      final lineIndicator = buildOrObtainChildFor(lineIndicatorVicinity)!;
      childrenCache[lineIndicatorVicinity] = lineIndicator;

      final lineIndicatorSize = lineIndicator.getDryLayout(constraints.loosen().copyWith(maxWidth: double.infinity));
      if (lineIndicatorSize.width > maxLineIndicatorWidth) {
        maxLineIndicatorWidth = lineIndicatorSize.width;
      }

      // We are required to set the layoutOffset for each obtained child,
      // even if we won't paint it. Otherwise, an assertion error is thrown.
      parentDataOf(lineIndicator).layoutOffset = const Offset(double.infinity, double.infinity);

      // Layout the code line.
      final codeLineVicinity = ChildVicinity(xIndex: 1, yIndex: i);
      final codeLine = buildOrObtainChildFor(codeLineVicinity)!;
      childrenCache[codeLineVicinity] = codeLine;

      codeLine.layout(constraints.loosen().copyWith(maxWidth: double.infinity), parentUsesSize: true);
      if (codeLine.size.width > maxLineWidth) {
        maxLineWidth = codeLine.size.width;
      }

      if (lineHeight == 0) {
        lineHeight = codeLine.size.height;
      }

      // We are required to set the layoutOffset for each obtained child,
      // even if we won't paint it. Otherwise, an assertion error is thrown.
      parentDataOf(codeLine).layoutOffset = const Offset(double.infinity, double.infinity);
    }

    // Now that we have maximum indicator width, layout each indicator with the same width.
    for (int i = 0; i <= maxRowIndex; i++) {
      final lineIndicatorVicinity = ChildVicinity(xIndex: 0, yIndex: i);
      final lineIndicator = childrenCache[lineIndicatorVicinity]!;
      lineIndicator.layout(constraints.copyWith(minWidth: maxLineIndicatorWidth, maxWidth: maxLineIndicatorWidth));
    }

    // First row that will be painted.
    final leadingRow = math.max((verticalPixels / lineHeight).floor(), 0);

    // Last row that will be painted.
    final trailingRow = math.min(((verticalPixels + viewportHeight) / lineHeight).ceil(), maxRowIndex);

    _leadingVicinity = ChildVicinity(xIndex: 0, yIndex: leadingRow);
    _trailingVicinity = ChildVicinity(xIndex: 1, yIndex: trailingRow);

    double yLayoutOffset = (leadingRow * lineHeight) - verticalOffset.pixels;

    // Compute the offset for each visible line.
    for (int row = leadingRow; row <= trailingRow; row++) {
      // Layout the indicator, which is pinned and scrolls only vertically.
      final lineIndicatorVicinity = ChildVicinity(xIndex: 0, yIndex: row);
      final lineIndicator = childrenCache[lineIndicatorVicinity]!;
      parentDataOf(lineIndicator).layoutOffset = Offset(0, yLayoutOffset);

      final codeLineVicinity = ChildVicinity(xIndex: 1, yIndex: row);
      final codeLine = childrenCache[codeLineVicinity]!;
      parentDataOf(codeLine).layoutOffset = Offset(maxLineIndicatorWidth - horizontalOffset.pixels, yLayoutOffset);

      // Move to the next line.
      yLayoutOffset += lineHeight;
    }

    // Set the min and max scroll extents for each axis.
    final verticalExtent = lineHeight * (maxRowIndex + 1);
    verticalOffset.applyContentDimensions(
      0.0,
      clampDouble(verticalExtent - viewportDimension.height, 0.0, double.infinity),
    );

    final horizontalExtent = maxLineWidth + maxLineIndicatorWidth;
    horizontalOffset.applyContentDimensions(
      0.0,
      clampDouble(horizontalExtent - viewportDimension.width, 0.0, double.infinity),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (clipBehavior != Clip.none) {
      _clipRectLayer.layer = context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & viewportDimension,
        _paintChildren,
        clipBehavior: clipBehavior,
        oldLayer: _clipRectLayer.layer,
      );
    } else {
      _clipRectLayer.layer = null;
      _paintChildren(context, offset);
    }
  }

  void _paintChildren(PaintingContext context, Offset offset) {
    // Paint only visible lines.
    for (int currentRow = _leadingVicinity.yIndex; currentRow <= _trailingVicinity.yIndex; currentRow++) {
      final codeLineVicinity = ChildVicinity(yIndex: currentRow, xIndex: 1);
      final codeLine = getChildFor(codeLineVicinity);
      if (codeLine != null) {
        context.paintChild(codeLine, parentDataOf(codeLine).layoutOffset! + offset);
      }

      // Paint the first column, which is pinned and scrolls only vertically.
      final lineIndicatorVicinity = ChildVicinity(yIndex: currentRow, xIndex: 0);
      final lineIndicator = getChildFor(lineIndicatorVicinity);
      if (lineIndicator != null) {
        context.paintChild(lineIndicator, parentDataOf(lineIndicator).layoutOffset! + offset);
      }
    }
  }
}

extension CodeLineLayoutFromContext on GlobalKey {
  /// Assumes this [GlobalKey] is attached to a [CodeLine] widget, and returns
  /// the [CodeLineLayout] for that line.
  ///
  /// This method is a verbosity reduction for repeated access of code line layouts.
  CodeLineLayout get asCodeLine => currentState as CodeLineLayout;
}

abstract interface class CodeLineLayout {
  /// Line number for this line within its overall source file, starting at zero.
  int get lineNumber;

  /// Returns `true` if the [globalOffset] is within the bounds of this code line.
  bool containsGlobalOffset(Offset globalOffset);

  /// Returns `true` if the given global [y] offset is within the bounds of this
  /// code line.
  bool containsGlobalYValue(double y);

  /// Returns the bounds that surround the word that appears at the given
  /// [globalOffset].
  CodeRange? findWordBoundaryAtGlobalOffset(Offset globalOffset);

  /// Returns the bounds that surround the word that appears at the given
  /// [localOffset].
  CodeRange? findWordBoundaryAtLocalOffset(Offset localOffset);

  /// Returns the [CodePosition] nearest to the given [globalOffset].
  CodePosition findCodePositionNearestGlobalOffset(Offset globalOffset);

  /// Returns the [CodePosition] nearest to the given [localOffset].
  CodePosition findCodePositionNearestLocalOffset(Offset localOffset);

  /// Returns a list of [TextBox]es that bound the given [selection],
  /// in local coordinates.
  ///
  /// See also:
  ///
  ///  * [RenderParagraph.getBoxesForSelection].
  List<TextBox> getBoxesForSelection(TextSelection selection);
}

class CodeSelection {
  const CodeSelection({required this.base, required this.extent});

  final CodePosition base;
  final CodePosition extent;

  CodeRange toRange() {
    final affinity = extent.line > base.line || extent.characterOffset >= base.characterOffset
        ? TextAffinity.downstream
        : TextAffinity.upstream;

    return CodeRange(
      affinity == TextAffinity.downstream ? base : extent,
      affinity == TextAffinity.downstream ? extent : base,
    );
  }
}

/// A range of code, from a starting line and offset, to an ending line and offset.
class CodeRange {
  const CodeRange(this.start, this.end) : assert(start <= end);

  final CodePosition start;
  final CodePosition end;

  CodeSelection toSelection([TextAffinity affinity = TextAffinity.downstream]) {
    return CodeSelection(
      base: affinity == TextAffinity.downstream ? start : end,
      extent: affinity == TextAffinity.downstream ? end : start,
    );
  }

  @override
  String toString() => "[CodeRange - $start -> $end]";
}

class CodePosition implements Comparable<CodePosition> {
  const CodePosition(this.line, this.characterOffset);

  final int line;
  final int characterOffset;

  bool operator <(CodePosition other) {
    return compareTo(other) < 0;
  }

  bool operator <=(CodePosition other) {
    return compareTo(other) <= 0;
  }

  bool operator >(CodePosition other) {
    return compareTo(other) > 0;
  }

  bool operator >=(CodePosition other) {
    return compareTo(other) >= 0;
  }

  @override
  int compareTo(CodePosition other) {
    if (line == other.line) {
      return characterOffset - other.characterOffset;
    }

    return line - other.line;
  }

  @override
  String toString() => "(line: $line, offset: $characterOffset)";
}

const lineColor = Color(0xFF1C2022);
const indentLineColor = Color(0xFF333333);
