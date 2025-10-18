import 'dart:io';

import 'package:aviary/infrastructure/file_io.dart';
import 'package:flutter/foundation.dart';
import 'package:git/git.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

class ProjectManager with ChangeNotifier {
  var isLoadingRecentProjects = false;

  bool get hasLoadedRecentProjects => _hasLoadedRecentProjects;
  var _hasLoadedRecentProjects = false;

  final recentProjects = <ProjectConfiguration>[];

  Future<void> loadRecentProjects() async {
    // TODO:

    _hasLoadedRecentProjects = true;

    notifyListeners();
  }
}

const flockConfiguration = ProjectConfiguration(
  name: "Flock",
  forkGitUrl: "https://github.com/join-the-flock/flock",
  patchesGitUrl: "https://github.com/join-the-flock/flock-patches",
);

class ProjectConfiguration {
  const ProjectConfiguration({required this.name, required this.forkGitUrl, required this.patchesGitUrl});

  final String name;
  final String forkGitUrl;
  final String patchesGitUrl;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectConfiguration &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          forkGitUrl == other.forkGitUrl &&
          patchesGitUrl == other.patchesGitUrl;

  @override
  int get hashCode => name.hashCode ^ forkGitUrl.hashCode ^ patchesGitUrl.hashCode;
}

class PatchesManifest {
  const PatchesManifest(this._file);

  final File _file;

  String get filePath => _file.path;

  Future<List<String>> readPatchList() async {
    final content = await _file.readAsString();
    return content.split("\n");
  }

  Future<void> writePatchList(List<String> patches) async {
    // TODO:
  }
}

class Project with ChangeNotifier {
  Project(this._projectConfiguration);

  final ProjectConfiguration _projectConfiguration;

  late Directory _projectDirectory;

  /// The [Directory] that holds the repository content for this fork's patches.
  ///
  /// This value is only available after successfully running [open].
  Directory get patchesDirectory => Directory("${_projectDirectory.path}${separator}patches");

  /// The [File] that holds the manifest of patches that comprise this fork.
  ///
  /// This value is only available after successfully running [open].
  PatchesManifest get patchesManifest => PatchesManifest(File("${patchesDirectory.path}$separator.patches"));

  /// The [Directory] that holds the repository content for this fork's Flutter project.
  ///
  /// This value is only available after successfully running [open].
  Directory get forkDirectory => Directory("${_projectDirectory.path}${separator}fork");

  bool get isOpen => _isOpen;
  var _isOpen = false;

  Future<void> open() async {
    if (_isOpen) {
      return;
    }

    // TODO: Add a logger
    final appDataDirectory = await getApplicationSupportDirectory();

    // Ensure we have a directory where we hold all the user's previously
    // opened projects.
    final projectsDirectory = appDataDirectory.subdirectory("projects");
    await projectsDirectory.create(recursive: true);

    // Projects are uniquely keyed by whatever name the user provides.
    _projectDirectory = projectsDirectory.subdirectory(_projectConfiguration.name);

    final projectExists = await _projectDirectory.exists();
    if (projectExists) {
      await _refreshProject(_projectConfiguration);
    } else {
      await _createNewProject(_projectConfiguration);
    }

    _isOpen = true;
    notifyListeners();
  }

  Future<void> _refreshProject(ProjectConfiguration projectConfiguration) async {
    print("Refreshing project at: '${_projectDirectory.path}'");

    // Ensure patches directory exists.
    final patchesDirectoryExists = await patchesDirectory.exists();
    if (!patchesDirectoryExists) {
      throw Exception("Tried to refresh an existing project, but there's no patches directory.");
    }

    // Fetch latest commits in the patches repository for this project.
    final patchesGitDir = await GitDir.fromExisting(patchesDirectory.path);
    final branches = ['master', 'beta', 'stable'];

    await patchesGitDir.runCommand(['fetch', 'origin']);

    final branchNameResult = await patchesGitDir.runCommand(['rev-parse', '--abbrev-ref', 'HEAD']);
    final currentBranch = branchNameResult.stdout.toString().trim();

    for (final branch in branches) {
      if (currentBranch == branch) {
        // We currently have this branch checked out. Pull it instead of fetching.
        final mergeResult = await patchesGitDir.runCommand(['merge', '--ff-only', 'origin/$branch']);

        final mergeExit = (mergeResult as dynamic).exitCode;
        if (mergeExit == 0) {
          print('Fast-forwarded current branch "$branch" to origin/$branch.');
        } else {
          // Fast-forward failed (diverged or other reason)
          final stderrText = mergeResult.stderr.toString().trim();
          print('Could not fast-forward "$branch": $stderrText');

          // Force reset to origin.
          print('Performing `git reset --hard origin/$branch` (destructive).');
          final resetResult = await patchesGitDir.runCommand(['reset', '--hard', 'origin/$branch']);
          final resetExit = (resetResult as dynamic).exitCode;
          if (resetExit == 0) {
            print('Reset current branch "$branch" to origin/$branch.');
          } else {
            print('Reset failed: ${resetResult.stderr}');
          }
        }

        continue;
      }

      final lsRemote = await patchesGitDir.runCommand(['ls-remote', '--heads', 'origin', branch]);
      if (lsRemote.stdout.toString().trim().isNotEmpty) {
        // Update the local branch from origin
        print("Pulling latest history for branch: $branch");
        final result = await patchesGitDir.runCommand(['fetch', 'origin', '$branch:$branch']);
        print(" - result (${result.exitCode}): ${result.stderr}");
      }
    }
    // TODO: emit progress events.

    // Ensure the fork directory exists.
    // TODO:

    // Fetch latest commits in the Flutter fork repository for this project.
    // TODO: emit progress events.
  }

  Future<void> _createNewProject(ProjectConfiguration projectConfiguration) async {
    // Create the directory where this project will be stored.
    await _projectDirectory.create(recursive: true);
    print("Creating new project in directory: '${_projectDirectory.path}'");

    // Clone the patches repository for this project.
    await patchesDirectory.create(recursive: true);
    final patchesGitDir = await GitDir.init(patchesDirectory.path);
    await patchesGitDir.runCommand(["remote", "add", "origin", projectConfiguration.patchesGitUrl]);
    await patchesGitDir.runCommand(["fetch", "origin"]);

    final result = await patchesGitDir.runCommand(['ls-remote', '--heads', 'origin', 'master']);
    final masterExists = result.stdout.toString().trim().isNotEmpty;
    if (masterExists) {
      await patchesGitDir.runCommand(["checkout", "-b", "master", "origin/master"]);
    }
    // TODO: emit progress events.

    // Clone the Flutter fork repository for this project.
    await forkDirectory.create(recursive: true);

    // TODO: emit progress events.

    print("Done creating new project");
  }
}
