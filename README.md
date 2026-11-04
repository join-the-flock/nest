# Nest
Tools for hatching new Flutters.

Learn more at https://getflocked.dev.

## Filing Issues
This repository is used to file issues for both Flock and Nest.

If you're having any issues with Flock or Nest, or if you have a feature request, please file a ticket under "Issues".

## What is Nest?
Nest is a collection of tools that make it easier to maintain a fork of Flutter.

There are various reasons that one might fork Flutter:

 * To fix a Flutter bug locally, while you wait for the Flutter team to fix it centrally.
 * To add needed features to Flutter that the Flutter team has chosen not to implement.
 * To port Flutter to a custom embedded system.

Forking Flutter requires constant maintenance:

 * Constantly synchronize with upstream Flutter changes, to stay up to date.
 * Build and deliver custom engine builds.

Nest aims to create and collect various scripts and apps that make it easier to maintain
and distribute Flutter forks.

## Importing and exporting channel patches

A shared patch repository can keep `.patches-master`, `.patches-beta`, and
`.patches-stable` on one branch. Each manifest lists the filenames to apply in
order. Patch files live together at the repository root; channels can share files
or select different dated adaptations of the same change.

Patch tools use Dart and Git. Install a standalone Dart SDK satisfying
`nest_patches/pubspec.yaml` and run `dart pub get --enforce-lockfile` in
`nest_patches/` first. They do not depend on the Flutter checkout's bundled Dart
SDK or on Python. Patch commands, collection handling, Git import/export, and
their tests live in the [`nest_patches`](nest_patches/README.md) Dart package.

Run these commands from the Nest repository, with the desired patch repository
checked out in `patches/` and the matching Flutter checkout in `flock/`:

```sh
dart run nest_patches/bin/git_import_patches.dart -p patches --channel stable -3
dart run nest_patches/bin/git_export_patches.dart -p patches --channel stable --dry-run
dart run nest_patches/bin/git_export_patches.dart -p patches --channel stable
```

Both commands accept `--flutter /path/to/sdk` to select a different Flutter
checkout, and `--manifest .patches-stable` is equivalent to `--channel stable`.
Channel collections require an explicit selection. Legacy repositories with only
`.patches` continue working without either option. Import records the included
upstream revision at `refs/patches/upstream-head` for subsequent exports.

Export replaces the selected manifest with the exported history in order. It
preserves filenames recorded in imported commits, including adaptation dates.
For a new compatibility adaptation, set its commit's `Patch-Filename:` line to
`<name>_YYYY-MM-DD.patch`, using the UTC date of the upstream change requiring
that adaptation. An unmarked new commit gets a baseline filename from its subject.
Dates identify adaptations; the manifests select which channels use them.

Export preserves other manifests and deletes a removed file only when it was
previously in the selected manifest and no other manifest references it. Unlisted
files are preserved. Changing a shared file's contents requires `--update-shared`;
that deliberately updates the file for every channel selecting it. Use a dated
adaptation when the implementations need to differ.

`--grep <text>` exports matching patch files while retaining the other selected
patches and their order. All commits belonging to a matching multi-commit file
are retained. `--dry-run` writes nothing and exits nonzero if changes would be
needed. Review the resulting diff and validate every affected channel before
committing.

The assembly action accepts the same selection through `patches_manifest`,
which defaults to `.patches` for existing callers. For the new layout, callers
must select patch repository ref `main` and the matching `.patches-<channel>`
manifest. Daily release and engine-build workflows use this selection: patch
repository `main`, with the manifest matching the Flutter channel. Flutter, Flock
distribution, and flock-demo branches remain channel-specific.
The assembly action installs Dart and resolves Nest dependencies before applying
patches, including when called from engine-build workflows.

For complete file ownership, add a `Patch-Replace-File: <path>` trailer to the
commit. Export emits the file as an unconditional replacement; import remembers
that choice for later exports. See the
[package README](nest_patches/README.md#replacing-complete-files) for details.

## Validation before daily publication

`tools/flock_publication_preflight_checks.dart` belongs to Nest. The daily rebase workflow runs it from
the Nest checkout on GitHub Actions, after assembling each channel and before
pushing that channel to `join-the-flock/flock`.

On that runner, Nest checks out upstream `flutter/flutter` into `flock/` and
applies the matching `.patches-master`, `.patches-beta`, or `.patches-stable`
manifest from the `main` branch of `join-the-flock/flock-patches`.
It also checks out `join-the-flock/flock-demo` into `flock-demo/`. The validation
script uses the assembled SDK in `flock/` to check the app in `flock-demo/`.
The script does not publish anything; Nest's next workflow step publishes only
if validation passes. A failure leaves that channel's existing remote branch
in place; the other channels can still publish if they pass.

Validation uses the assembled SDK's `bin/flutter` directly. It checks that the
SDK starts, reports the assembled revision and expected channel, and uses the
pinned engine. It then resolves dependencies for `join-the-flock/flock-demo`,
runs its analysis and widget tests, and builds it for web in release mode. It also
checks that validation did not change the assembled revision or tracked files.

The workflow runs from Nest's `main` branch and checks out the demo's `master`,
`beta`, or `stable` branch to match the Flock channel being assembled. Every Flutter
command uses the assembled SDK directly, bypassing the demo's FVM configuration
so that validation never installs the already-published Flock distribution.

Each run uploads a `flock-validation-<channel>` artifact with the assembly and
demo revisions, version output, and validation log. `success.txt` is only written
after all checks pass. The validation step has a 45-minute timeout, and runs for the
same channel cannot publish concurrently.

To run the checks locally, use the Nest repository as your working directory.
First assemble Flock on the corresponding channel and check out flock-demo
alongside Nest. For a local SDK at `nest/flock/` and demo at `../flock-demo/`:

```sh
dart pub get
dart run tools/flock_publication_preflight_checks.dart --flutter-path flock --demo-path ../flock-demo --channel master --report-dir /tmp/flock-validation
```

Check out the matching demo branch first, and use a separate report directory per run.
Validation writes dependency and build outputs into the demo checkout, so use a
disposable checkout if you want to keep your demo working directory untouched.
Validation requires network access for SDK artifacts and pub dependencies.
This is a Linux smoke test in the daily
workflow, not the full Flutter test suite or validation of custom engine builds.
Native platforms, including Flock's iOS logging patch, need separate engine
build and platform tests before those binaries are distributed.

Nest's integration tests live in `test/`. Run `dart pub get --enforce-lockfile`
and `dart test` from the Nest repository. Then run the same commands from
`nest_patches/` for the package's own tests. The patch-tool tests exercise
real imports and exports in temporary Git repositories, including channel
isolation, multi-commit round trips, file additions, edits, deletions, renames,
executable modes, symlinks, binary payloads,
CRLF and Unicode text, empty files, missing final newlines, commit metadata,
three-way merges, conflict recovery, and invalid inputs. Run analysis with
`dart analyze tools/flock_publication_preflight_checks.dart test` in Nest
and `dart analyze` in `nest_patches/`.
Workflow tests verify that every assembly caller selects patch repository `main`
and the manifest matching its Flutter channel.
The publication preflight tests simulate Flutter command responses. These tests
do not download Flutter or contact the Flock or flock-demo repositories.
Nest's `test-publication-preflight.yaml`
workflow runs analysis and these tests on pull requests and pushes that change
the tools, assembly action, tests, package dependencies, analyzer configuration,
or the related workflows. It runs from the Nest checkout on GitHub Actions using
stable Dart, without assembling Flock.

The daily publication workflow does not run Nest's unit tests. It resolves
Nest's Dart dependencies and runs the real preflight checks against that day's
assembled SDK and the matching flock-demo checkout. Those demo checks always
invoke the assembled SDK's `bin/flutter` directly.
