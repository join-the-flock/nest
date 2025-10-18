import 'package:flutter/material.dart';

class PatchesPane extends StatelessWidget {
  const PatchesPane({
    super.key,
    required this.patchFileNames,
    this.selectedPatchFileName,
    required this.manifestPath,
    required this.onPatchFilePressed,
  });

  final List<String> patchFileNames;
  final String? selectedPatchFileName;

  final String manifestPath;

  final void Function(String patchFileName) onPatchFilePressed;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF220B26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildAppBar(),
          Divider(height: 1, color: Color(0xFF202529)),
          _buildPatchesHeader(),
          Expanded(child: _buildPatchList()),
          _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildAppBar() {
    return SizedBox(
      height: 52,
      child: Center(
        child: Text("Flock", style: TextStyle(color: Colors.white, fontSize: 12, letterSpacing: 3)),
      ),
    );
  }

  Widget _buildPatchesHeader() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        color: const Color(0xFF301036),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          "PATCHES", //
          textAlign: TextAlign.center,
          style: TextStyle(color: const Color(0xFF7D5284), fontSize: 11, letterSpacing: 2),
        ),
      ),
    );
  }

  Widget _buildPatchList() {
    return ListView(
      children: [
        for (int i = 0; i < patchFileNames.length; i += 1) //
          PatchListItem(
            // i + 1 so we start at "1" instead of "0".
            indexInManifest: i + 1,
            name: patchFileNames[i],
            isActive: patchFileNames[i] == selectedPatchFileName,
            onPressed: () => onPatchFilePressed(patchFileNames[i]),
          ),
      ],
    );
  }

  Widget _buildFooter() {
    return Container(
      color: const Color(0xFF301036),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Text(
                manifestPath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: const Color(0xFF7D5285), fontSize: 11, letterSpacing: 1),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Icon(Icons.open_in_new, size: 16, color: const Color(0xFF7D5285)),
          ),
        ],
      ),
    );
  }
}

class PatchListItem extends StatefulWidget {
  const PatchListItem({
    super.key,
    required this.indexInManifest,
    required this.name,
    this.isActive = false,
    required this.onPressed,
  });

  final int indexInManifest;
  final String name;

  final bool isActive;

  final VoidCallback onPressed;

  @override
  State<PatchListItem> createState() => _PatchListItemState();
}

class _PatchListItemState extends State<PatchListItem> {
  bool _isHovering = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() {
        _isHovering = true;
      }),
      onExit: (_) => setState(() {
        _isHovering = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() {
          _isPressed = true;
        }),
        onTapUp: (_) => setState(() {
          _isPressed = false;
          widget.onPressed();
        }),
        onTapCancel: () => setState(() {
          _isPressed = false;
        }),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: _backgroundColor, borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: _indexCircleDecoration,
                  child: Center(
                    child: Text("${widget.indexInManifest}", style: TextStyle(color: _labelColor, fontSize: 12)),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: Text(widget.name, style: TextStyle(color: _labelColor, fontSize: 12)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  BoxDecoration get _indexCircleDecoration {
    if (widget.isActive) {
      return BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.transparent,
        border: Border.all(color: const Color(0xFFAD38C2)),
      );
    }

    return BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF323A40));
  }

  Color get _labelColor {
    if (widget.isActive || _isHovering) {
      return Colors.white;
    }

    return const Color(0xFF7D7D7D);
  }

  Color get _backgroundColor {
    if (widget.isActive) {
      return const Color(0xFF642070);
    }
    if (_isHovering) {
      return const Color(0xFF37123D);
    }
    if (_isPressed) {
      return const Color(0xFF4B1854);
    }

    return Colors.transparent;
  }
}
