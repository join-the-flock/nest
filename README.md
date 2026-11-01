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

## Validation before daily publication

`tools/flock_publication_preflight_checks.dart` belongs to Nest. The daily rebase workflow runs it from
the Nest checkout on GitHub Actions, after assembling each channel and before
pushing that channel to `join-the-flock/flock`.

On that runner, Nest checks out upstream `flutter/flutter` into `flock/` and
applies the matching channel's patches from `join-the-flock/flock-patches`.
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

Nest's own tests live in `test/flock_publication_preflight_checks_test.dart`. Run `dart pub get` and
`dart test` from the Nest repository. These tests simulate Flutter command
responses in temporary checkouts; they do not download Flutter or contact the
Flock or flock-demo repositories. Nest's `test-publication-preflight.yaml`
workflow runs analysis and these tests on pull requests and pushes that change
the preflight script, tests, package dependencies, analyzer configuration, or
the related workflows. It runs from the Nest checkout on GitHub Actions using
stable Dart, without assembling Flock.

The daily publication workflow does not run Nest's unit tests. It resolves
Nest's Dart dependencies and runs the real preflight checks against that day's
assembled SDK and the matching flock-demo checkout. Those demo checks always
invoke the assembled SDK's `bin/flutter` directly.
