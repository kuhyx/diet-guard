import 'dart:io';

/// Deletes the picked file at [path]; a failure is not worth a crash.
Future<void> discardPickedFile(String path) async {
  try {
    await File(path).delete();
  } on FileSystemException {
    // Already gone, or not ours to delete: the bytes were read, which is all
    // that mattered.
  }
}
