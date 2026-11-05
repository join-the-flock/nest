# nest_patches

Dart tools for importing, exporting, and managing ordered collections of Git mail
patches. Requires Git and a standalone Dart SDK satisfying `pubspec.yaml`.

The package owns patch collection validation, channel manifests, commit metadata,
and Git import/export. It supports standard Git patches and unconditional file
replacements.

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

## Resetting an existing assembly

Normal import expects a fresh upstream checkout. If a recorded upstream base
exists, HEAD must be at that revision. Existing assembled commits are rejected
with guidance to use `--reset`. Imported patch metadata also identifies assembled
histories whose private upstream reference was not cloned. On the first import
without a recorded base, HEAD is treated as upstream.

To rebuild from the recorded upstream base and current patches, run from Nest:

```sh
dart run nest_patches/bin/git_import_patches.dart \
  --flutter flock --patches-dir patches --channel master --reset
```

Export commits you want included in the rebuilt fork first. Reset refuses staged,
unstaged, or untracked work and requires a recorded upstream commit that is an
ancestor of HEAD. It validates patch syntax and mail metadata, prints a backup
reference under `refs/patches/backups/`, resets to the recorded base, and applies the
selected patches. The local recorded base is assumed to be compatible; no
separate patch-collection base is required. Ignored SDK caches remain; ignored
files that would be overwritten cause refusal. Reset does not fetch Flutter,
upgrade its revision, or switch upstream channels. A different manifest selects
different patches for the same
recorded base.

To recover the old committed history, replace `<printed-backup-reference>` with
the reference printed by the command and create a branch at it:

```sh
git -C flock switch -c recovered-assembly <printed-backup-reference>
```

If patch application fails during `--reset`, the importer aborts its own
`git am` session and restores the checkout to the recorded upstream base with
no patches applied. It reports the failure and keeps the pre-reset backup. Fix
the patches or choose the appropriate upstream checkout before retrying. Normal
imports without `--reset` retain their existing manual conflict-recovery behavior.
A clone without the private upstream reference cannot use `--reset`; start from
a fresh upstream checkout and import once to establish the base.

## Replacing complete files

Add a `Patch-Replace-File: README.md` trailer to the commit that should own the
entire file. Export emits its complete contents with a `replace file mode`
header. Import replaces the file regardless of upstream contents and preserves
the intent for re-export. Repeat the trailer for multiple paths.

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
