import 'dart:io';

import 'package:aviary/features/project/patch_editor_pane.dart';
import 'package:aviary/features/project/patch_list_pane.dart';
import 'package:aviary/features/welcome/loading_page.dart';
import 'package:aviary/infrastructure/project_manager.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart';

class ProjectScreen extends StatefulWidget {
  const ProjectScreen({super.key, required this.projectConfiguration});

  final ProjectConfiguration projectConfiguration;

  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends State<ProjectScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(body: OpenProjectPage(projectConfiguration: widget.projectConfiguration));
  }
}

class OpenProjectPage extends StatefulWidget {
  const OpenProjectPage({super.key, required this.projectConfiguration});

  final ProjectConfiguration projectConfiguration;

  @override
  State<OpenProjectPage> createState() => _OpenProjectPageState();
}

class _OpenProjectPageState extends State<OpenProjectPage> {
  late Project _project;

  final _patches = <String>[];

  File? _selectedPatchFile = null;
  String? _selectedPathFileName = null;

  @override
  void initState() {
    super.initState();

    _project = Project(widget.projectConfiguration);
    _openProject();
  }

  Future<void> _openProject() async {
    print("Opening project (${widget.projectConfiguration.name}) at ${widget.projectConfiguration.patchesGitUrl}");
    await _project.open();
    if (!mounted) {
      return;
    }

    // TODO: Look for the patches file, read it, show the patches
    final patches = await _project.patchesManifest.readPatchList();
    print("Patches: $patches");
    if (!mounted) {
      return;
    }

    setState(() {
      _patches
        ..clear()
        ..addAll(patches);
    });
  }

  void _openPatchFile(String patchFileName) {
    setState(() {
      _selectedPatchFile = File("${_project.patchesDirectory.path}$separator$patchFileName");
      _selectedPathFileName = patchFileName;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: _project,
        builder: (context, child) {
          if (!_project.isOpen) {
            return LoadingPage();
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 400,
                child: PatchesPane(
                  patchFileNames: _patches,
                  selectedPatchFileName: _selectedPathFileName,
                  manifestPath: _project.patchesManifest.filePath,
                  onPatchFilePressed: _openPatchFile,
                ),
              ),
              Container(width: 1, color: Colors.white.withValues(alpha: 0.1)),
              Expanded(child: PatchFileEditor(patchFile: _selectedPatchFile)),
            ],
          );
        },
      ),
    );
  }
}
