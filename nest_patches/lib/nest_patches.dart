/// Tools for importing, exporting, and managing Git mail patch collections.
library;

export 'src/patch_cli.dart' show runPatchTool;
export 'src/patch_collection.dart';
export 'src/patch_git.dart' show importPatches, exportPatches, upstreamHead;
export 'src/patch_protocol.dart';
export 'src/repair_cli.dart' show runRepairTool;
