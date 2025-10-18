import 'dart:io';

import 'package:path/path.dart';

extension DirectoryExtensions on Directory {
  Directory subdirectory(String name) => Directory("$path$separator$name");
}
