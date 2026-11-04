/// Tools for importing, exporting, and managing Git mail patch collections.
library;

export 'src/patch_cli.dart' show runPatchTool;
export 'src/patch_collection.dart';
export 'src/patch_git.dart' show importPatches, exportPatches, upstreamHead;
