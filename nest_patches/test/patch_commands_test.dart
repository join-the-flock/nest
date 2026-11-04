import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('Patch command integration >', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('nest commands-');
    });
    tearDown(() => root.deleteSync(recursive: true));

    for (final command in ['git_import_patches', 'git_export_patches']) {
      test('$command runs from another directory', () async {
        final result = await _command(command, ['--help'], root);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(result.stdout, contains('--patches-dir'));
        expect(result.stdout, contains('--channel'));
      });
    }

    test('Dart commands export and import a patch collection', () async {
      final source = Directory('${root.path}/source')..createSync();
      final target = Directory('${root.path}/target');
      final patches = Directory('${root.path}/patches')..createSync();
      await _git(source, ['init', '-q']);
      await _configure(source);
      File('${source.path}/base.txt').writeAsStringSync('base\n');
      await _git(source, ['add', '.']);
      await _git(source, ['commit', '-qm', 'Base']);
      await _git(source, ['update-ref', 'refs/patches/upstream-head', 'HEAD']);
      final clone =
          await Process.run('git', ['clone', source.path, target.path]);
      expect(clone.exitCode, 0, reason: '${clone.stderr}');
      await _configure(target);

      File('${source.path}/feature.txt').writeAsStringSync('feature\n');
      await _git(source, ['add', '.']);
      await _git(source, ['commit', '-qm', 'Add feature']);
      final exported = await _command(
          'git_export_patches', ['-f', source.path, '-p', patches.path], root);
      expect(exported.exitCode, 0, reason: '${exported.stderr}');
      expect(File('${patches.path}/.patches').readAsStringSync(),
          'add_feature.patch\n');

      final imported = await _command('git_import_patches',
          ['-f', target.path, '-p', patches.path, '-3'], root);
      expect(imported.exitCode, 0, reason: '${imported.stderr}');
      expect(
          File('${target.path}/feature.txt').readAsStringSync(), 'feature\n');
      expect(await _git(target, ['rev-parse', 'HEAD^{tree}']),
          await _git(source, ['rev-parse', 'HEAD^{tree}']));
      expect(await _git(target, ['status', '--porcelain']), isEmpty);
    });
  });
}

Future<ProcessResult> _command(
        String name, List<String> arguments, Directory workingDirectory) =>
    Process.run(Platform.resolvedExecutable,
        ['run', '${Directory.current.path}/bin/$name.dart', ...arguments],
        workingDirectory: workingDirectory.path);

Future<String> _git(Directory repository, List<String> arguments) async {
  final result =
      await Process.run('git', ['-C', repository.path, ...arguments]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return (result.stdout as String).trim();
}

Future<void> _configure(Directory repository) async {
  await _git(repository, ['config', 'user.name', 'Nest tests']);
  await _git(repository, ['config', 'user.email', 'nest@example.invalid']);
  await _git(repository, ['config', 'commit.gpgsign', 'false']);
  await _git(repository, ['config', 'core.hooksPath', '/dev/null']);
}
