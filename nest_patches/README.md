# nest_patches

Dart tools for importing, exporting, and managing ordered collections of Git mail
patches. Requires Git and a standalone Dart SDK satisfying `pubspec.yaml`.

The package owns patch collection validation, channel manifests, commit metadata,
and Git import/export. It currently uses standard Git patch syntax; custom
replacement syntax has not been added.

## Commands

From this package directory:

```sh
dart pub get --enforce-lockfile
dart run bin/git_import_patches.dart -f /path/to/repository -p /path/to/patches --channel stable -3
dart run bin/git_export_patches.dart -f /path/to/repository -p /path/to/patches --channel stable --dry-run
```

Use `--help` for options. Collections containing channel manifests require an
explicit `--channel` or `--manifest` selection. Legacy `.patches` collections do
not. From the Nest directory, invoke these entry points with
`dart run nest_patches/bin/git_import_patches.dart` or
`dart run nest_patches/bin/git_export_patches.dart`. Relative repository and patch
paths are resolved from the current working directory.

## Library

Import `package:nest_patches/nest_patches.dart` for collection operations,
`importPatches`, `exportPatches`, and the command runner `runPatchTool`.
`importPatches` takes prepared mail data; `readPatchCollection` reads the ordered
files and attaches their source metadata before import. Export uses that metadata
to preserve filenames, then removes it from the exported descriptions.

## Tests

```sh
dart analyze
dart test
```

Tests use temporary Git repositories and exercise file operations, binary and
text payloads, metadata, merges, conflict recovery, manifest validation, shared
patches, filtered exports, and multi-commit round trips. They require no Flutter
checkout. Command tests also verify invocation from another working directory.
Nest separately tests its workflow wiring.
