/// Named-document persistence, independent of where the documents live.
library;

/// Reads and writes whole documents by name (`food_log.json`,
/// `food_bank.json`, `app_settings.json`).
///
/// Deliberately free of `dart:io` so the storage services compile for web:
/// the desktop app is a Flutter web build, and a single `dart:io` import
/// anywhere in the graph turns into a stub that throws at runtime (a blank
/// white window, not a build error). Implementations live in
/// `document_store_io.dart` (files) and `document_store_web.dart`
/// (IndexedDB), selected by the conditional export in
/// `document_store_factory.dart`.
///
/// Whole-document rather than key-value because every caller already
/// serialises a complete JSON structure, and a partial write of any of them
/// would be worse than none.
abstract class DocumentStore {
  /// Returns the stored contents of [name], or null if nothing is stored.
  Future<String?> read(String name);

  /// Overwrites [name] with [contents].
  Future<void> write(String name, String contents);
}
