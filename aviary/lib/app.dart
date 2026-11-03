import 'package:aviary/features/project/project_screen.dart';
import 'package:aviary/features/welcome/welcome_screen.dart';
import 'package:aviary/infrastructure/project_manager.dart';
import 'package:flutter/material.dart';

// TODO: Prompt user for a fork configuration:
//       - URL for a patches repository
//       - URL for a Flutter fork repository
// TODO: Clone the patches repo in a local cache
// TODO: Display the patch list from the patches repo
// TODO: Let the user select a patches branch
// TODO: Let the user visualize a selected patch file

// TODO: UI -> Toolbar at top to select branch, patches to the left, patch file to the right.

class AviaryApp extends StatefulWidget {
  const AviaryApp({super.key});

  @override
  State<AviaryApp> createState() => _AviaryAppState();
}

class _AviaryAppState extends State<AviaryApp> {
  ProjectConfiguration? _projectConfiguration;

  void _openProject(ProjectConfiguration projectConfiguration) {
    setState(() {
      _projectConfiguration = projectConfiguration;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aviary',
      theme: ThemeData(brightness: Brightness.dark),
      home: _buildScreen(),
      debugShowCheckedModeBanner: false,
    );
  }

  Widget _buildScreen() {
    if (_projectConfiguration == null) {
      return WelcomeScreen(onProjectSelected: _openProject);
    }

    return ProjectScreen(projectConfiguration: _projectConfiguration!);
  }
}
