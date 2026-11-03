import 'package:aviary/infrastructure/project_manager.dart';
import 'package:flutter/material.dart';

class PickProjectPage extends StatelessWidget {
  const PickProjectPage({
    super.key,
    required this.projectManager,
    required this.onNewProjectPressed,
    required this.onProjectSelected,
  });

  final ProjectManager projectManager;

  final VoidCallback onNewProjectPressed;
  final void Function(ProjectConfiguration config) onProjectSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // TODO: Implement support for custom projects
            // _buildHeader("New Project".toUpperCase()),
            // _ProjectListItem(
            //   title: "Configure",
            //   subtitle: "Tell us where to find your Nest",
            //   buttonLabel: "Get Started",
            //   onOpenPressed: onNewProjectPressed,
            // ),
            // Divider(height: 36, color: Colors.white.withValues(alpha: 0.1)),
            _buildHeader("Community Projects".toUpperCase()),
            _ProjectListItem(
              title: "Flock",
              subtitle: "Flutter by the community, for the community",
              buttonLabel: "Open",
              onOpenPressed: () => onProjectSelected(flockConfiguration),
            ),
            if (projectManager.recentProjects.isNotEmpty) ...[
              Divider(height: 36, color: Colors.white.withValues(alpha: 0.1)),
              _buildHeader("Recent Projects".toUpperCase()),
              for (final project in projectManager.recentProjects)
                _ProjectListItem(
                  title: project.name,
                  subtitle: project.forkGitUrl,
                  buttonLabel: "Open",
                  onOpenPressed: () => onProjectSelected(project),
                ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Text(
        text,
        style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _ProjectListItem extends StatelessWidget {
  const _ProjectListItem({required this.title, required this.subtitle, required this.buttonLabel, this.onOpenPressed});

  final String title;
  final String subtitle;
  final String buttonLabel;

  final VoidCallback? onOpenPressed;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      spacing: 8,
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title.toUpperCase(),
                style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 10, height: 1)),
            ],
          ),
        ),
        Button(
          sizeConstraints: BoxConstraints(minWidth: 80, minHeight: 30, maxHeight: 30),
          label: buttonLabel,
          onPressed: onOpenPressed,
        ),
      ],
    );
  }
}

class Button extends StatefulWidget {
  const Button({
    super.key,
    required this.sizeConstraints,
    required this.label,
    this.style = const ButtonStyle(),
    this.onPressed,
  });

  final BoxConstraints sizeConstraints;

  final String label;

  final ButtonStyle style;

  final VoidCallback? onPressed;

  @override
  State<Button> createState() => _ButtonState();
}

class _ButtonState extends State<Button> {
  final _statesController = WidgetStatesController();

  @override
  void initState() {
    super.initState();

    _statesController.update(WidgetState.disabled, widget.onPressed == null);
  }

  @override
  void didUpdateWidget(Button oldWidget) {
    super.didUpdateWidget(oldWidget);

    _statesController.update(WidgetState.disabled, widget.onPressed == null);
  }

  @override
  void dispose() {
    _statesController.dispose();
    super.dispose();
  }

  bool get _isEnabled => widget.onPressed != null;

  Color get _labelColor {
    return widget.style.labelColor.resolve(_statesController.value);
  }

  Color get _backgroundColor {
    return widget.style.background.resolve(_statesController.value);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _statesController,
      builder: (context, child) {
        return GestureDetector(
          onTapDown: (_) {
            _statesController.update(WidgetState.pressed, true);
          },
          onTapUp: (_) {
            _statesController.update(WidgetState.pressed, false);
            widget.onPressed?.call();
          },
          onTapCancel: () {
            _statesController.update(WidgetState.pressed, false);
          },
          child: MouseRegion(
            cursor: _isEnabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
            onEnter: (_) => _statesController.update(WidgetState.hovered, true),
            onExit: (_) => _statesController.update(WidgetState.hovered, false),
            child: Focus(
              onFocusChange: (focused) => _statesController.update(WidgetState.focused, focused),
              child: ConstrainedBox(
                constraints: widget.sizeConstraints,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        offset: Offset(0, !_statesController.value.contains(WidgetState.pressed) ? 2 : 0),
                        blurRadius: !_statesController.value.contains(WidgetState.pressed) ? 6 : 1,
                      ),
                    ],
                  ),
                  child: BoxWithGradientBorder(
                    background: _backgroundColor,
                    borderRadius: 3,
                    borderGradient: LinearGradient(
                      colors: [widget.style.borderTopColor, widget.style.borderBottomColor],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          widget.label,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: _labelColor, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class ButtonStyle {
  const ButtonStyle({
    this.labelColor = defaultButtonLabelColor,
    this.background = defaultButtonBackgroundColor,
    this.borderTopColor = const Color(0x10FFFFFF),
    this.borderBottomColor = const Color(0x0C000000),
  });

  final WidgetStateColor labelColor;

  final WidgetStateColor background;
  final Color borderTopColor;
  final Color borderBottomColor;
}

const defaultButtonLabelColor = WidgetStateColor.fromMap({
  WidgetState.disabled: Color(0x44FFFFFF),
  WidgetState.pressed: Color(0x88FFFFFF),
  WidgetState.hovered: Colors.white,
  WidgetState.any: Colors.white,
});

const defaultButtonBackgroundColor = WidgetStateColor.fromMap({
  WidgetState.disabled: Color(0xFF3F4E63),
  WidgetState.pressed: Color(0xFF394759),
  WidgetState.hovered: Color(0xFF46576e),
  WidgetState.any: Color(0xFF3F4E63),
});

class BoxWithGradientBorder extends StatelessWidget {
  const BoxWithGradientBorder({
    super.key,
    this.background = Colors.transparent,
    this.borderRadius = 0,
    this.borderThickness = 1,
    required this.borderGradient,
    this.child,
  });

  final Color background;

  final double borderRadius;
  final double borderThickness;
  final LinearGradient borderGradient;

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: RRectBorderGradientPainter(
        background: background,
        borderRadius: borderRadius,
        borderThickness: borderThickness,
        borderGradient: borderGradient,
      ),
      child: child,
    );
  }
}

class RRectBorderGradientPainter extends CustomPainter {
  const RRectBorderGradientPainter({
    this.background = Colors.transparent,
    this.borderRadius = 0,
    this.borderThickness = 1,
    required this.borderGradient,
  });

  final Color background;

  final double borderRadius;
  final double borderThickness;
  final LinearGradient borderGradient;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..drawRRect(
        RRect.fromLTRBR(0, 0, size.width, size.height, Radius.circular(borderRadius)),
        Paint()..color = background,
      )
      ..drawRRect(
        RRect.fromLTRBR(0, 0, size.width, size.height, Radius.circular(borderRadius)),
        Paint()
          ..shader = borderGradient.createShader(Offset.zero & size)
          ..style = PaintingStyle.stroke
          ..strokeWidth = borderThickness,
      );
  }

  @override
  bool shouldRepaint(RRectBorderGradientPainter oldDelegate) {
    return background != oldDelegate.background ||
        borderRadius != oldDelegate.borderRadius ||
        borderThickness != oldDelegate.borderThickness ||
        borderGradient != oldDelegate.borderGradient;
  }
}
