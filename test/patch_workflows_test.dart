import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('Patch workflow integration >', () {
    final callers = _assemblyCallers().toList();

    test('finds assembly callers in the release and engine-build workflows',
        () {
      expect(callers.map((caller) => caller.workflow).toSet(), {
        'daily-flock-rebase.yaml',
        'build-and-upload-engine-variants.yaml',
      });
    });

    group('Channel manifest selection >', () {
      for (final caller in callers) {
        test(
            '${caller.job} reads main and the matching Flutter channel manifest',
            () {
          expect(caller.inputs['patches_ref'], 'main', reason: caller.workflow);
          final flutterRef = caller.inputs['flutter_ref'];
          expect(flutterRef, isNotNull, reason: caller.workflow);
          expect(caller.inputs['patches_manifest'], '.patches-$flutterRef',
              reason:
                  '${caller.workflow}: select the Flutter channel, not the Nest or patches branch');
        });
      }
    });

    group('Daily releases >', () {
      final workflow = _workflow('daily-flock-rebase.yaml');
      final job =
          (workflow['jobs'] as YamlMap)['rebase-flock-on-flutter'] as YamlMap;
      final steps = (job['steps'] as YamlList).cast<YamlMap>();

      test('assembles all three Flutter channels', () {
        final strategy = job['strategy'] as YamlMap;
        expect((strategy['matrix'] as YamlMap)['config'],
            ['master', 'beta', 'stable']);
        expect(strategy['fail-fast'], isFalse);
      });

      test('keeps the demo checkout on the matching channel', () {
        final checkout = steps.singleWhere((step) =>
            step['with'] is YamlMap &&
            (step['with'] as YamlMap)['repository'] ==
                'join-the-flock/flock-demo');
        expect((checkout['with'] as YamlMap)['ref'], r'${{ matrix.config }}');
      });

      test('publishes to the matching Flock distribution channel', () {
        final publish = steps.singleWhere(
            (step) => step['uses'] == './.github/actions/push-flock-repo');
        expect((publish['with'] as YamlMap)['destination_branch'],
            r'${{ matrix.config }}');
      });
    });

    test('engine builds select an official Flutter channel', () {
      final environment =
          _workflow('build-and-upload-engine-variants.yaml')['env'] as YamlMap;
      expect(['master', 'beta', 'stable'],
          contains(environment['FLUTTER_BRANCH']));
    });

    test('CI runs these tests when any assembly caller changes', () {
      final events =
          _workflow('test-publication-preflight.yaml')['on'] as YamlMap;
      for (final event in ['pull_request', 'push']) {
        final paths = (events[event] as YamlMap)['paths'] as YamlList;
        expect(paths, containsAll(['nest_patches/**', 'tools/**']));
        for (final workflow
            in callers.map((caller) => caller.workflow).toSet()) {
          expect(paths, contains('.github/workflows/$workflow'), reason: event);
        }
      }
    });

    test('CI resolves and tests nest_patches as an independent package', () {
      final workflow = _workflow('test-publication-preflight.yaml');
      final job = (workflow['jobs'] as YamlMap)['test-preflight'] as YamlMap;
      final steps = (job['steps'] as YamlList).cast<YamlMap>().toList();
      final packageSteps = steps
          .where((step) => step['working-directory'] == 'nest_patches')
          .toList();
      expect(packageSteps, hasLength(2));
      expect(packageSteps.first['run'], 'dart pub get --enforce-lockfile');
      expect(packageSteps.last['run'], contains('dart analyze'));
      expect(packageSteps.last['run'], contains('dart test'));
    });

    test('assembly installs independent Dart and resolves Nest before patching',
        () {
      final action = loadYaml(File('.github/actions/assemble-flock/action.yaml')
          .readAsStringSync()) as YamlMap;
      final steps = ((action['runs'] as YamlMap)['steps'] as YamlList)
          .cast<YamlMap>()
          .toList();
      final setup =
          steps.indexWhere((step) => step['uses'] == 'dart-lang/setup-dart@v1');
      final dependencies = steps.indexWhere(
          (step) => step['run'] == 'dart pub get --enforce-lockfile');
      final apply = steps.indexWhere((step) => '${step['run']}'
          .contains('dart run nest_patches/bin/git_import_patches.dart -p'));
      expect(setup, greaterThanOrEqualTo(0));
      expect(dependencies, greaterThan(setup));
      expect(apply, greaterThan(dependencies));
      expect(steps[dependencies]['working-directory'],
          r'${{ github.action_path }}/../../..');
      final patchDependencies = steps.indexWhere((step) =>
          step['working-directory'] ==
          r'${{ github.action_path }}/../../../nest_patches');
      expect(patchDependencies, greaterThan(setup));
      expect(apply, greaterThan(patchDependencies));
      expect(
          steps[patchDependencies]['run'], 'dart pub get --enforce-lockfile');
    });
  });
}

Iterable<_AssemblyCaller> _assemblyCallers() sync* {
  final directory = Directory('.github/workflows');
  final files = directory
      .listSync()
      .whereType<File>()
      .where(
          (file) => file.path.endsWith('.yaml') || file.path.endsWith('.yml'))
      .toList()
    ..sort((first, second) => first.path.compareTo(second.path));
  for (final file in files) {
    final document = loadYaml(file.readAsStringSync()) as YamlMap;
    final jobs = document['jobs'] as YamlMap;
    for (final entry in jobs.entries) {
      final job = entry.value as YamlMap;
      if (job['steps'] case final YamlList steps) {
        for (final step in steps.cast<YamlMap>()) {
          if (step['uses'] == './.github/actions/assemble-flock') {
            yield _AssemblyCaller(file.uri.pathSegments.last,
                entry.key as String, step['with'] as YamlMap);
          }
        }
      }
    }
  }
}

class _AssemblyCaller {
  _AssemblyCaller(this.workflow, this.job, this.inputs);

  final String workflow;
  final String job;
  final YamlMap inputs;
}

YamlMap _workflow(String name) =>
    loadYaml(File('.github/workflows/$name').readAsStringSync()) as YamlMap;
