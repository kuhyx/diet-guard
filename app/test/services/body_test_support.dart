// Shared fakes for the Body feature's tests: an in-memory DocumentStore and
// an in-memory RemoteStore (path -> text), enough for `syncLog` and the
// wake-alarm ingestion, which only list directories and read/write files.

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/services/document_store.dart';

/// Documents kept in a map.
class MemoryDocStore implements DocumentStore {
  /// Stored documents by name.
  final Map<String, String> documents = {};

  @override
  Future<String?> read(String name) async => documents[name];

  @override
  Future<void> write(String name, String contents) async {
    documents[name] = contents;
  }
}

/// A RemoteStore over a flat `path -> text` map.
class MemoryRemote implements RemoteStore {
  /// Creates the store, optionally pre-seeded with [files].
  MemoryRemote([Map<String, String>? files]) : files = {...?files};

  /// Every file, by full path.
  final Map<String, String> files;

  /// Set to make every call throw, to test failure handling.
  Object? failWith;

  void _maybeFail() {
    final error = failWith;
    if (error != null) throw error;
  }

  @override
  Future<List<String>> listDirectory(String path) async {
    _maybeFail();
    final prefix = '$path/';
    return {
      for (final key in files.keys)
        if (key.startsWith(prefix)) key.substring(prefix.length).split('/')[0],
    }.toList();
  }

  @override
  Future<String?> getFileText(String path) async {
    _maybeFail();
    return files[path];
  }

  @override
  Future<void> putFileText(
    String path,
    String text, {
    required String message,
  }) async {
    _maybeFail();
    files[path] = text;
  }

  @override
  Future<void> deleteFile(String path, {String message = ''}) async {
    files.remove(path);
  }

  @override
  Future<bool> canAccessRemote() async => true;

  @override
  void close() {}
}
