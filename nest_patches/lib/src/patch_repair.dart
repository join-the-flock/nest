part of 'patch_git.dart';

/// A repair owns its Git am session and keeps its journal inside the checkout's
/// Git directory. The original branch is repaired in place, never replaced by
/// a second checkout or a temporary branch.
Future<Directory> _repairDirectory(String repository) async {
  final path =
      (await git(repository, ['rev-parse', '--git-path', 'nest-patch-repair']))
          .trim();
  return Directory(p.isAbsolute(path) ? path : p.join(repository, path));
}

Future<String?> _repairBranch(String repository) async {
  final result = await Process.run(
      'git', ['-C', repository, 'symbolic-ref', '--quiet', 'HEAD']);
  if (result.exitCode == 1) return null;
  if (result.exitCode != 0) {
    throw ProcessException(
        'git', ['symbolic-ref', 'HEAD'], '${result.stderr}', result.exitCode);
  }
  return (result.stdout as String).trim();
}

Future<void> _checkRepairOperations(String repository,
    {bool allowAm = false}) async {
  for (final operation in [
    'rebase-apply',
    'rebase-merge',
    'MERGE_HEAD',
    'CHERRY_PICK_HEAD',
    'REVERT_HEAD',
    'sequencer'
  ]) {
    if (allowAm && operation == 'rebase-apply') continue;
    final path =
        (await git(repository, ['rev-parse', '--git-path', operation])).trim();
    if (FileSystemEntity.typeSync(
            p.isAbsolute(path) ? path : p.join(repository, path)) !=
        FileSystemEntityType.notFound) {
      throw FormatException(
          'A Git operation is in progress ($operation); finish it before starting repair');
    }
  }
}

Future<void> _saveRepair(
    Directory directory, Map<String, dynamic> state) async {
  final pending = File(p.join(directory.path, 'state.pending'));
  pending.writeAsStringSync(jsonEncode(state), flush: true);
  pending.renameSync(p.join(directory.path, 'state.json'));
}

Map<String, String> _repairCollection(String directory) {
  final result = <String, String>{};
  for (final entry in Directory(directory).listSync()) {
    final name = p.basename(entry.path);
    if (!name.endsWith('.patch') &&
        !['.patches', ...channelManifests].contains(name)) continue;
    if (FileSystemEntity.isLinkSync(entry.path) || entry is! File) {
      throw FormatException(
          'Patch collection entries must be regular files: $name');
    }
    result[name] = entry.readAsStringSync();
  }
  return result;
}

Future<void> startPatchRepair(String repository, String directory,
    {required String channel, String? adaptationDate, String? base}) async {
  if (!['master', 'beta', 'stable'].contains(channel)) {
    throw FormatException('Unsupported repair channel: $channel');
  }
  final session = await _repairDirectory(repository);
  if (session.existsSync()) {
    throw FormatException(
        'A patch repair is already active; use --continue, --export, or --abort');
  }
  await _checkRepairOperations(repository);
  await _requireCleanReset(repository);
  final head =
      (await git(repository, ['rev-parse', '--verify', 'HEAD^{commit}']))
          .trim();
  final recorded = await _recordedUpstream(repository);
  final oldBase = (await git(repository,
          ['rev-parse', '--verify', '${base ?? recorded ?? head}^{commit}']))
      .trim();
  final String target;
  try {
    target = (await git(repository,
            ['rev-parse', '--verify', 'refs/remotes/origin/$channel^{commit}']))
        .trim();
  } on ProcessException {
    throw FormatException('No fetched upstream revision at origin/$channel. '
        'Fetch origin in the fork checkout before starting repair');
  }
  final selection = resolveManifest(directory, '.patches-$channel');
  final snapshot = _repairCollection(directory);
  final mails = splitPatches(readPatchCollection(directory, selection))
      .map(PatchMail.parse)
      .toList();
  if (mails.isEmpty) throw FormatException('The patch collection is empty');
  if (mails.any((mail) => mail.replacementPaths.isNotEmpty)) {
    throw FormatException(
        'Patch-Replace-File is reserved import metadata; use replace file mode');
  }
  final destinations = <String>{};
  await _validateResetPatches(repository, mails, destinations);
  await _checkIgnoredCollisions(repository, head, target, destinations);
  // Reconstruct preimages from the known working base. This populates Git's
  // object database using a scratch index, without editing the working files.
  try {
    await _planReplacements(repository, mails, threeway: false, base: oldBase);
  } on ProcessException catch (error) {
    throw FormatException('Cannot reconstruct the patches at base $oldBase. '
        'Use --base <last-working-upstream-commit> if needed.\n$error');
  }
  final date = adaptationDate ??
      DateTime.parse(
              (await git(repository, ['show', '-s', '--format=%cI', target]))
                  .trim())
          .toUtc()
          .toIso8601String()
          .substring(0, 10);
  validatePatchNames(['adaptation_$date.patch'], selection);
  await git(repository, ['var', 'GIT_COMMITTER_IDENT']);
  await _requireCleanReset(repository);
  if ((await git(repository, ['rev-parse', 'HEAD'])).trim() != head) {
    throw FormatException('HEAD changed while preparing repair; retry');
  }
  final backup =
      'refs/patches/backups/repair-${DateTime.now().toUtc().microsecondsSinceEpoch}';
  await git(repository, ['update-ref', backup, head, '0' * head.length]);
  session.createSync();
  final state = <String, dynamic>{
    'version': 1,
    'repository': p.normalize(p.absolute(repository)),
    'patches': p.normalize(p.absolute(directory)),
    'manifest': selection,
    'originalHead': head,
    'originalBase': recorded,
    'branch': await _repairBranch(repository),
    'onto': target,
    'date': date,
    'backup': backup,
    'snapshot': snapshot,
    'mails': [
      for (final mail in mails)
        [...mail.message, for (final file in mail.files) ...file.lines].join()
    ],
    'index': 0,
    'pending': false,
    'before': target,
    'adapted': <String>[],
    'phase': 'starting',
  };
  await _saveRepair(session, state);
  stdout.writeln('Repairing $selection against origin/$channel ($target).');
  stdout.writeln('Saved starting history at $backup');
  await git(repository, ['reset', '--hard', target]);
  final pinned = await pinEngine(repository);
  await git(repository, ['update-ref', upstreamHead, pinned]);
  state['onto'] = pinned;
  state['before'] = pinned;
  state['phase'] = 'applying';
  await _saveRepair(session, state);
  await _advanceRepair(session, state);
}

String _repairFilename(PatchMail mail) => mail.message
    .firstWhere((line) => line.startsWith(patchFilenamePrefix))
    .substring(patchFilenamePrefix.length)
    .trimRight();

/// Translate only the replacement images. Leave ordinary diffs as originally
/// authored so Git am can attempt direct application before a three-way merge.
Future<String> _repairMail(String repository, PatchMail mail) async {
  final temporary = Directory.systemTemp.createTempSync('nest-repair-mail-');
  final environment = {'GIT_INDEX_FILE': p.join(temporary.path, 'index')};
  try {
    final patch = File(p.join(temporary.path, 'patch'));
    final paths = await _inspectMailFiles(repository, mail, patch);
    if (paths.isEmpty)
      return [...mail.message, for (final file in mail.files) ...file.lines]
          .join();
    await git(repository, ['read-tree', 'HEAD'], environment: environment);
    for (final path in paths) {
      await git(repository, ['update-index', '--force-remove', '--', path],
          environment: environment);
    }
    patch.writeAsStringSync(mail.files
        .where((file) => file.replacementMode != null)
        .map((file) => file.gitDiff)
        .join());
    await git(
        repository,
        [
          'apply',
          '--cached',
          '--allow-empty',
          '--whitespace=nowarn',
          patch.path
        ],
        environment: environment);
    final tree =
        (await git(repository, ['write-tree'], environment: environment))
            .trim();
    final diff = await git(repository, [..._treeDiffOptions, 'HEAD', tree]);
    return mail
        .withDiff(
            [
              for (final file
                  in mail.files.where((file) => file.replacementMode == null))
                file.gitDiff,
              diff,
            ].join(),
            replacements: paths)
        .join();
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

Future<void> _advanceRepair(
    Directory session, Map<String, dynamic> state) async {
  final repository = state['repository'] as String;
  final mails = (state['mails'] as List).cast<String>();
  while (state['index'] < mails.length) {
    final index = state['index'] as int;
    final mail = PatchMail.parse(patchLines(mails[index]));
    final before = (await git(repository, ['rev-parse', 'HEAD'])).trim();
    state['before'] = before;
    state['pending'] = true;
    await _saveRepair(session, state);
    final data = await _repairMail(repository, mail);
    stdout.writeln(
        'Applying patch ${index + 1} of ${mails.length}: ${_repairFilename(mail)}');
    try {
      await _applyMail(repository, data,
          threeway: false,
          keepEmpty: true,
          preserveWhitespace: true,
          quiet: true);
    } on ProcessException {
      await _restoreImportBase(repository, before);
      final name = _repairFilename(mail);
      if (!(state['adapted'] as List).contains(name))
        (state['adapted'] as List).add(name);
      await _saveRepair(session, state);
      try {
        await _applyMail(repository, data,
            threeway: true, keepEmpty: true, preserveWhitespace: true);
      } on ProcessException {
        stdout.writeln(
            'Stopped at patch ${index + 1} of ${mails.length}: $name\n'
            'Resolve the files in $repository, then run repair with --continue.\n'
            'Use --abort to restore the starting checkout.');
        throw FormatException('Patch repair needs conflict resolution');
      }
    }
    state['index'] = index + 1;
    state['pending'] = false;
    state['before'] = (await git(repository, ['rev-parse', 'HEAD'])).trim();
    await _saveRepair(session, state);
  }
  state['phase'] = 'ready';
  state['repairHead'] = state['before'];
  await _saveRepair(session, state);
  stdout.writeln('All patches applied in $repository. Run the relevant tests, '
      'then use git_export_patches.dart to export adaptations and any new development commits.');
}

Future<void> resumePatchRepair(String repository, String operation) async {
  final session = await _repairDirectory(repository);
  final file = File(p.join(session.path, 'state.json'));
  if (!file.existsSync())
    throw FormatException('No patch repair is active in $repository');
  final state = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  if (state['version'] != 1)
    throw FormatException('Unsupported repair session version');
  if (await _repairBranch(repository) != state['branch']) {
    throw FormatException(
        'The checkout branch changed; return to the branch where repair started');
  }
  await _checkRepairOperations(repository, allowAm: state['pending'] == true);
  if (operation == 'abort') {
    await _restoreImportBase(repository, state['originalHead'] as String);
    if (state['originalBase'] == null) {
      await git(repository, ['update-ref', '-d', upstreamHead]);
    } else {
      await git(repository,
          ['update-ref', upstreamHead, state['originalBase'] as String]);
    }
    session.deleteSync(recursive: true);
    stdout.writeln(
        'Repair aborted; restored the starting branch and upstream base.');
    return;
  }
  if (state['phase'] == 'starting') {
    throw FormatException(
        'Repair preparation was interrupted; use --abort and start again');
  }
  if (operation == 'export') {
    if (state['phase'] != 'ready')
      throw FormatException(
          'Resolve and continue the remaining patches before exporting');
    await _exportRepair(session, state);
    return;
  }
  if (operation != 'continue')
    throw FormatException('Unknown repair operation: $operation');
  if (state['phase'] == 'ready') {
    stdout.writeln(
        'Repair is complete; run tests, then use git_export_patches.dart.');
    return;
  }
  final before = state['before'] as String;
  final head = (await git(repository, ['rev-parse', 'HEAD'])).trim();
  final amPath =
      (await git(repository, ['rev-parse', '--git-path', 'rebase-apply']))
          .trim();
  final applying =
      Directory(p.isAbsolute(amPath) ? amPath : p.join(repository, amPath))
          .existsSync();
  if (state['pending'] == true && applying) {
    if (head != before)
      throw FormatException(
          'HEAD changed during conflict resolution; restore the repair HEAD before continuing');
    final paths = (await git(repository, ['diff', '--name-only', 'HEAD', '-z']))
        .split('\x00')
        .where((path) => path.isNotEmpty);
    for (final path in paths) {
      final file = File(p.join(repository, path));
      if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
              FileSystemEntityType.file &&
          RegExp(r'^(<<<<<<< |=======\r?$|>>>>>>> )', multiLine: true).hasMatch(
              utf8.decode(file.readAsBytesSync(), allowMalformed: true))) {
        throw FormatException('Unresolved conflict markers in $path');
      }
    }
    final mail = PatchMail.parse(
        patchLines((state['mails'] as List)[state['index']] as String));
    final temporary = Directory.systemTemp.createTempSync('nest-repair-paths-');
    try {
      final paths = <String>{};
      await _inspectMailFiles(
          repository, mail, File(p.join(temporary.path, 'patch')),
          destinations: paths);
      await git(repository, ['add', '--update']);
      for (final path in paths) {
        if (FileSystemEntity.typeSync(p.join(repository, path)) !=
            FileSystemEntityType.notFound) {
          await git(repository, ['--literal-pathspecs', 'add', '--', path]);
        }
      }
    } finally {
      temporary.deleteSync(recursive: true);
    }
    final staged = await Process.run(
        'git', ['-C', repository, 'diff', '--cached', '--quiet']);
    if (staged.exitCode != 0 && staged.exitCode != 1) {
      throw FormatException(
          'Cannot inspect the staged resolution: ${staged.stderr}');
    }
    if (staged.exitCode == 0) {
      final skipped = state.putIfAbsent('skipped', () => <String>[]) as List;
      final name = _repairFilename(mail);
      if (!skipped.contains(name)) skipped.add(name);
      await _saveRepair(session, state);
    }
    stdout.write(await git(repository, [
      '-c',
      'core.editor=true',
      '-c',
      'commit.gpgsign=false',
      'am',
      staged.exitCode == 0 ? '--skip' : '--continue',
    ]));
    state['index'] = (state['index'] as int) + 1;
    state['pending'] = false;
    state['before'] = (await git(repository, ['rev-parse', 'HEAD'])).trim();
    await _saveRepair(session, state);
  } else if (head != before) {
    // Git may have completed the commit just before the journal was saved.
    // Recognize exactly one child carrying this pending patch's metadata.
    final mail = state['pending'] == true
        ? PatchMail.parse(
            patchLines((state['mails'] as List)[state['index']] as String))
        : null;
    final fields =
        (await git(repository, ['show', '-s', '--format=%P%x00%B', head]))
            .split('\x00');
    if (mail == null ||
        fields.length != 2 ||
        fields[0] != before ||
        !patchLines(fields[1]).any((line) =>
            line.trimRight() ==
            '$patchFilenamePrefix${_repairFilename(mail)}')) {
      throw FormatException(
          'HEAD changed outside repair; use --abort to restore the starting state');
    }
    state['index'] = (state['index'] as int) + 1;
    state['pending'] = false;
    state['before'] = head;
    await _saveRepair(session, state);
  }
  await _requireCleanReset(repository);
  await _advanceRepair(session, state);
}

Future<void> _exportRepair(Directory session, Map<String, dynamic> state,
    {bool dryRun = false, bool updateShared = false}) async {
  final repository = state['repository'] as String;
  final directory = state['patches'] as String;
  final manifest = state['manifest'] as String;
  final snapshot = (state['snapshot'] as Map).cast<String, String>();
  void checkCollection() {
    final current = _repairCollection(directory);
    if (current.length != snapshot.length ||
        snapshot.entries.any((e) => current[e.key] != e.value)) {
      throw FormatException(
          'The patch collection changed during repair; export refused. Your repaired checkout is preserved');
    }
  }

  checkCollection();
  await _checkRepairOperations(repository);
  await _requireCleanReset(repository);
  final head = (await git(repository, ['rev-parse', 'HEAD'])).trim();
  final repairHead =
      state['repairHead'] as String? ?? state['before'] as String;
  final checkpoint = await Process.run('git',
      ['-C', repository, 'merge-base', '--is-ancestor', repairHead, head]);
  if (checkpoint.exitCode != 0) {
    throw FormatException('The completed repair history was rewritten. '
        'Keep the repaired history and add development commits on top before exporting');
  }
  state['repairHead'] = repairHead;
  final onto = state['onto'] as String;
  final ancestor = await Process.run(
      'git', ['-C', repository, 'merge-base', '--is-ancestor', onto, 'HEAD']);
  if (ancestor.exitCode != 0)
    throw FormatException(
        'The repaired history no longer contains the target upstream commit');
  final temporary = Directory.systemTemp.createTempSync('nest-repair-export-');
  try {
    final candidate = Directory(p.join(temporary.path, 'patches'))
      ..createSync();
    for (final entry in snapshot.entries)
      File(p.join(candidate.path, entry.key)).writeAsStringSync(entry.value);
    final adaptations = <String, String>{};
    final obsolete = <String>{};
    final newNames =
        (await _formatPatchSeries(repository, '$repairHead..$head'))
            .map(_filename)
            .toSet();
    final repairedNames = (state['adapted'] as List).cast<String>().toSet();
    final adaptationNames = {
      for (final name in repairedNames)
        '${patchIdentity(name)}_${state['date']}.patch'
    };
    for (final name in (state['adapted'] as List).cast<String>()) {
      final adapted = '${patchIdentity(name)}_${state['date']}.patch';
      final currentName = state['renamed'] == true ? adapted : name;
      final staged = Directory(p.join(temporary.path, 'selected'))
        ..createSync();
      await _exportPatches(repository, staged.path,
          patchRange: '$onto..$head',
          manifest: manifest,
          grep: '$patchFilenamePrefix$currentName\n');
      final exported = File(p.join(staged.path, currentName));
      if (!exported.existsSync()) {
        final messages =
            await git(repository, ['log', '--format=%B', '$onto..HEAD']);
        if (!patchLines(messages).any((line) =>
                line.trimRight() == '$patchFilenamePrefix$currentName') &&
            !((state['skipped'] as List?) ?? []).contains(name)) {
          throw FormatException(
              'Repaired commit lost its Patch-Filename metadata: $name');
        }
        // A resolved patch can be entirely obsolete on the new upstream.
        obsolete.add(name);
        staged.deleteSync(recursive: true);
        continue;
      }
      if (adapted != name &&
          snapshot.containsKey(adapted) &&
          snapshot[adapted] != exported.readAsStringSync()) {
        throw FormatException(
            'Adaptation filename already exists: $adapted; restart with another --adaptation-date');
      }
      adaptations[adapted] = exported.readAsStringSync();
      staged.deleteSync(recursive: true);
    }
    if (adaptations.isNotEmpty)
      writePatchCollection(candidate.path, manifest, adaptations,
          partial: true, updateShared: updateShared);
    final selected = {
      for (final name in readManifest(candidate.path, manifest))
        if (!obsolete.contains(name))
          name: File(p.join(candidate.path, name)).readAsStringSync(),
    };
    if (newNames.isNotEmpty) {
      // Generate the full history once so a later commit intentionally extending
      // an existing patch retains its earlier mails and normal grouping rules.
      final generated = Directory(p.join(temporary.path, 'all'))..createSync();
      await _exportPatches(repository, generated.path,
          patchRange: '$onto..$head', manifest: manifest);
      for (final name in newNames) {
        if (repairedNames.contains(name) ||
            state['renamed'] == true && adaptationNames.contains(name))
          continue;
        if (adaptationNames.contains(name)) {
          throw FormatException(
              'New patch collides with a repaired adaptation: $name');
        }
        selected[name] = File(p.join(generated.path, name)).readAsStringSync();
      }
    }
    writePatchCollection(candidate.path, manifest, selected,
        updateShared: updateShared);
    final mails = splitPatches(readPatchCollection(candidate.path, manifest))
        .map(PatchMail.parse)
        .toList();
    // Direct application from the target cannot fall back to retained old blobs.
    final replay =
        await _planReplacements(repository, mails, threeway: false, base: onto);
    final expected =
        (await git(repository, ['rev-parse', 'HEAD^{tree}'])).trim();
    if (replay.tree != expected)
      throw FormatException(
          'Fresh replay differs from the repaired checkout; no patches exported');
    checkCollection();
    if ((await git(repository, ['rev-parse', 'HEAD'])).trim() != head) {
      throw FormatException('HEAD changed during export; retry');
    }
    await _requireCleanReset(repository);
    if (dryRun) {
      writePatchCollection(directory, manifest, selected,
          updateShared: updateShared, dryRun: true);
      stdout
          .writeln('Fresh replay verified (dry run); repair session retained.');
      return;
    }
    if (state['renamed'] != true && (state['adapted'] as List).isNotEmpty) {
      await _renameRepairCommits(repository, state);
      state['renamed'] = true;
      state['before'] = (await git(repository, ['rev-parse', 'HEAD'])).trim();
      await _saveRepair(session, state);
    }
    checkCollection();
    writePatchCollection(directory, manifest, selected,
        updateShared: updateShared);
    session.deleteSync(recursive: true);
    stdout.writeln(
        'Fresh replay verified. Exported ${adaptations.length} adaptation(s) and subsequent development patches for $manifest.\n'
        'Review the patch collection diff. Starting history remains at ${state['backup']}.');
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

/// Keep export filenames in commit metadata too, so later ordinary exports do
/// not resurrect the superseded variant. Recreate only commits needing a new
/// message or parent, preserving their trees, authors, and dates.
Future<void> _renameRepairCommits(
    String repository, Map<String, dynamic> state) async {
  final oldHead = (await git(repository, ['rev-parse', 'HEAD'])).trim();
  final onto = state['onto'] as String;
  final commits =
      (await git(repository, ['rev-list', '--reverse', '$onto..HEAD']))
          .trim()
          .split('\n')
          .where((commit) => commit.isNotEmpty);
  var parent = onto;
  final repairHead = state['repairHead'] as String;
  String? updatedRepairHead;
  for (final commit in commits) {
    final fields = (await git(repository, [
      'show',
      '-s',
      '--format=%T%x00%P%x00%an%x00%ae%x00%aI%x00%cn%x00%ce%x00%cI%x00%B',
      commit
    ]))
        .split('\x00');
    if (fields.length != 9 || fields[1].split(' ').length != 1) {
      throw FormatException('Repair export requires a linear patch history');
    }
    final original = fields[8].replaceFirst(RegExp(r'\n$'), '');
    var message = original;
    for (final name in (state['adapted'] as List).cast<String>()) {
      message = message.replaceAll(
          RegExp('^${RegExp.escape(patchFilenamePrefix + name)}\$',
              multiLine: true),
          '$patchFilenamePrefix${patchIdentity(name)}_${state['date']}.patch');
    }
    if (message == original && parent == fields[1]) {
      parent = commit;
      if (commit == repairHead) updatedRepairHead = parent;
      continue;
    }
    final process = await Process.start('git', [
      '-C',
      repository,
      '-c',
      'commit.gpgsign=false',
      'commit-tree',
      fields[0],
      '-p',
      parent
    ], environment: {
      'GIT_AUTHOR_NAME': fields[2],
      'GIT_AUTHOR_EMAIL': fields[3],
      'GIT_AUTHOR_DATE': fields[4],
      'GIT_COMMITTER_NAME': fields[5],
      'GIT_COMMITTER_EMAIL': fields[6],
      'GIT_COMMITTER_DATE': fields[7],
    });
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    process.stdin.write(message);
    await process.stdin.close();
    final code = await process.exitCode;
    final result = await output;
    final diagnostics = await errors;
    if (code != 0)
      throw ProcessException('git', ['commit-tree'], diagnostics, code);
    parent = result.trim();
    if (commit == repairHead) updatedRepairHead = parent;
  }
  await git(repository, ['update-ref', 'HEAD', parent, oldHead]);
  state['repairHead'] = updatedRepairHead ?? repairHead;
}

/// Route the ordinary exporter through an active repair's checkpoint and
/// snapshot, without recursively routing the scratch exports used to plan it.
Future<bool> _tryExportRepair(String repository, String directory,
    {String? manifest,
    String? patchRange,
    String? grep,
    required bool dryRun,
    required bool updateShared}) async {
  final session = await _repairDirectory(repository);
  if (!session.existsSync()) return false;
  final journal = File(p.join(session.path, 'state.json'));
  if (!journal.existsSync())
    throw FormatException(
        'Incomplete repair session; restore it before exporting');
  final state = jsonDecode(journal.readAsStringSync()) as Map<String, dynamic>;
  if (state['version'] != 1)
    throw FormatException('Unsupported repair session version');
  if (state['phase'] != 'ready') {
    throw FormatException(
        'Patch repair is unfinished; resolve conflicts and use repair --continue before exporting');
  }
  if (await _repairBranch(repository) != state['branch']) {
    throw FormatException(
        'The checkout branch changed; return to the branch where repair started');
  }
  if (!Directory(directory).existsSync() ||
      Directory(directory).resolveSymbolicLinksSync() !=
          Directory(state['patches'] as String).resolveSymbolicLinksSync()) {
    throw FormatException(
        'Export must use the active repair patch collection: ${state['patches']}');
  }
  if (manifest != null && manifest != state['manifest']) {
    throw FormatException(
        'Export must use the active repair manifest: ${state['manifest']}');
  }
  if (patchRange != null || grep != null) {
    throw FormatException(
        'An active repair must export its complete history; omit the range and --grep');
  }
  await _exportRepair(session, state,
      dryRun: dryRun, updateShared: updateShared);
  return true;
}
