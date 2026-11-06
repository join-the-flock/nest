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
not. Export can infer the selection from a completed repair session. From the Nest directory, invoke these entry points with
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

## Generated engine pins

For Flutter checkouts, import pins the upstream engine before applying patches.
It runs the tracked `bin/internal/update_engine_version.sh` with inherited engine
and realm overrides cleared. A generated pin is force-added (Flutter ignores
this file by default) and committed with `Nest-Engine-Pin: true`. That commit
becomes `refs/patches/upstream-head`, so exports start after it and reset keeps
it. Existing upstream pins are reused without a generated commit. Generic Git
repositories without Flutter's tracked script retain their existing behavior.
Repair selects a new pin from its fetched target before replaying patches.

The engine version file is generated metadata: export omits it even in explicit
ranges or when it has been folded into a published patch commit. Nest's
`publish-fork` action uses `git_publication_revision.dart` to construct the same
SDK tree without the standalone local pin commits in published ancestry. It
never rewrites the development checkout. See Nest's engine-pin documentation
for publication restrictions and custom engine selection.

## Replacing complete files

Add a `Patch-Replace-File: README.md` trailer to the commit that should own the
entire file. Export emits its complete contents with a `replace file mode`
header. Import replaces the file regardless of upstream contents and preserves
the intent for re-export. Repeat the trailer for multiple paths.

## Repairing patches after upstream changes

Repair operates in the existing fork directory and on its current branch. Export
any changes you want to keep in the collection first. The checkout must have no
staged, unstaged, or untracked work. Fetch the upstream revision explicitly, then
start repair from Nest:

```sh
git -C flock fetch origin
dart run nest_patches/bin/git_repair_patches.dart \
  --flutter flock --patches-dir patches --channel master
```

The channel selects both `.patches-<channel>` and the fetched
`origin/<channel>` branch. The command prints the resolved upstream commit, saves
the starting commit under a backup reference, moves the current branch to that
upstream commit, and replays patches in order. The target stays pinned for the
session even if the remote-tracking branch changes later.
Before moving history, it reconstructs the old patch preimages using the recorded
upstream base and an isolated Git index. If necessary, supply
`--base <last-working-upstream-commit>`. No extra working directory or branch is
created, and no upstream revision is fetched implicitly.

When a patch conflicts, edit the files in `flock/`, then run:

```sh
dart run nest_patches/bin/git_repair_patches.dart --continue
```

Continue remembers the collection, manifest, target commit, and remaining patches.
It stages tracked resolution edits and the patch's added files, preserves author
and description metadata, and resumes application. Repeat for further conflicts.
Complete file replacements retain their unconditional behavior.

After all patches apply, you can add development commits on top of the repaired
history. Run the relevant tests on the fork, then use the normal export command:

```sh
dart run nest_patches/bin/git_export_patches.dart \
  --flutter flock --patches-dir patches --channel master
```

Export first verifies that the candidate collection applies directly from the
target upstream tree, with three-way merging disabled, and produces exactly the
current tree, including the additional commits. It writes dated adaptations for
patches that needed three-way merging, updates only the selected manifest, and
preserves variants used by other channels. Commit filename metadata is updated
too, so later exports remember the
adaptation. New development commits become ordinary patches, appended to the
selected manifest; their filenames are derived from their subjects or explicit
`Patch-Filename` metadata. File replacement intent is preserved in both repaired
and new patches. Export may recreate commits to update filename metadata and
parent references; it retains their authors, dates, and contents. If resolving a
conflict keeps the upstream contents with no remaining change, that mail is
skipped; a wholly obsolete patch is removed from the selected manifest while
other channels retain their version. The default date is the
target commit's UTC committer date; use
`--adaptation-date YYYY-MM-DD` when starting repair to specify the date of the
upstream change that required the adaptation. Concurrent collection edits cause
export to refuse without overwriting them. Review the resulting collection diff
and run CI across channels before merging.

Export recognizes the session automatically and can infer its channel when
`--channel` is omitted. An explicit channel or manifest and the collection path
must match the repair session. Partial exports using a range or `--grep` are
refused while repair is active, so the complete collection can be verified.
`--dry-run` reports pending changes without rewriting commits, writing patches,
or closing the session. A successful export closes the repair session. The repair
command's `--export` remains an alias for this complete export.

To abandon a repair, including uncommitted resolution edits:

```sh
dart run nest_patches/bin/git_repair_patches.dart --abort
```

Abort restores the starting commit and recorded upstream base on the same branch.
Ignored SDK caches remain. Session state lives in the checkout's Git directory;
use the same `--flutter` path on subsequent commands if it differs from `flock/`.
Repair blocks ordinary import/reset until the session is exported or aborted.
Reset's existing rollback-on-failure behavior is unchanged.

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
