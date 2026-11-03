import 'package:aviary/features/welcome/loading_page.dart';
import 'package:aviary/features/welcome/new_project_page.dart';
import 'package:aviary/features/welcome/pick_project_page.dart';
import 'package:aviary/infrastructure/project_manager.dart';
import 'package:flutter/material.dart';
import 'package:grid_paper/grid_paper.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, required this.onProjectSelected});

  final void Function(ProjectConfiguration) onProjectSelected;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: _BackgroundDotGrid()),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(76),
              child: _WelcomeFlow(onProjectSelected: widget.onProjectSelected),
            ),
          ),
        ],
      ),
    );
  }
}

class _WelcomeFlow extends StatefulWidget {
  const _WelcomeFlow({required this.onProjectSelected});

  final void Function(ProjectConfiguration) onProjectSelected;

  @override
  State<_WelcomeFlow> createState() => _WelcomeFlowState();
}

class _WelcomeFlowState extends State<_WelcomeFlow> {
  final _projectManager = ProjectManager();

  var _step = _WelcomeFlowStep.initialize;

  @override
  void initState() {
    super.initState();
    _initializeProjectManager();
  }

  Future<void> _initializeProjectManager() async {
    await _projectManager.loadRecentProjects();
    if (!mounted) {
      return;
    }

    setState(() {
      _step = _WelcomeFlowStep.pickProject;
    });
  }

  void _newProject() {
    setState(() {
      _step = _WelcomeFlowStep.newProject;
    });
  }

  void _openProject(ProjectConfiguration config) {
    widget.onProjectSelected(config);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _projectManager,
      builder: (context, child) {
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: ColoredBox(
              color: Color(0xFF2F3B4C),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(),
                  Flexible(child: _buildPage()),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPage() {
    switch (_step) {
      case _WelcomeFlowStep.initialize:
        return LoadingPage();
      case _WelcomeFlowStep.pickProject:
        return PickProjectPage(
          projectManager: _projectManager,
          onNewProjectPressed: _newProject,
          onProjectSelected: _openProject,
        );
      case _WelcomeFlowStep.newProject:
        return NewProjectPage();
    }
  }
}

enum _WelcomeFlowStep { initialize, pickProject, newProject }

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 200,
      color: Colors.pinkAccent,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "NEST",
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 14, fontWeight: FontWeight.bold),
            ),
            Text("AVIARY", style: TextStyle(fontSize: 32, fontWeight: FontWeight.w200, letterSpacing: 12)),
          ],
        ),
      ),
    );
  }
}

class _BackgroundDotGrid extends StatelessWidget {
  const _BackgroundDotGrid();

  @override
  Widget build(BuildContext context) {
    return DotMatrixPaper(
      gridUnitSize: 50,
      background: const Color(0xFF111111),
      style: DotMatrixStyle(
        dotColor: Colors.white.withValues(alpha: 0.1),
        dividerColor: Colors.white.withValues(alpha: 0.15),
        divider: DotMatrixDivider.cross,
      ),
    );
  }
}
