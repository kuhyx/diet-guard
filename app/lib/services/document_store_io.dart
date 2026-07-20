/// File-backed [DocumentStore] used on Android (and any `dart:io` platform).
library;

import 'dart:io';

import 'package:diet_guard_app/services/document_store.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// [DocumentStore] backed by one file per document.
///
/// Document names are the full on-disk filenames (`food_log.json`, …) rather
/// than bare keys, so the files an already-installed phone holds keep their
/// exact paths through this refactor -- renaming them would look to the app
/// like a device with no history.
class FileDocumentStore implements DocumentStore {
  /// Creates a store keeping its documents under [directory].
  FileDocumentStore(this.directory);

  /// Directory holding the document files.
  final Directory directory;

  File _fileFor(String name) => File(p.join(directory.path, name));

  @override
  Future<String?> read(String name) async {
    final file = _fileFor(name);
    if (!file.existsSync()) return null;
    try {
      return await file.readAsString();
    } on FileSystemException {
      // An unreadable file is treated as absent; callers fall back to empty
      // rather than failing to start.
      return null;
    }
  }

  /// Writes to a unique temp file then atomically renames it over the real
  /// one, so a concurrent reader never observes a half-written document.
  ///
  /// The temp name carries both the pid and a per-process counter: the pid
  /// separates the foreground app from the connectivity-gated background
  /// push, which can `runSync` -> write from a separate isolate, and the
  /// counter separates two overlapping writes *within* one process (two
  /// setters awaiting the same document would otherwise both create the same
  /// temp file, and the second rename would fail with the first's file
  /// already gone).
  @override
  Future<void> write(String name, String contents) async {
    final file = _fileFor(name);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.$pid.${_writeCounter++}.tmp');
    await tmp.writeAsString(contents);
    await tmp.rename(file.path);
  }

  static int _writeCounter = 0;
}

/// Opens the platform document store (the app's documents directory).
// coverage:ignore-start
Future<DocumentStore> openDocumentStore() async =>
    FileDocumentStore(await getApplicationDocumentsDirectory());
// coverage:ignore-end
