/// File-backed [BlobStore] used on Android.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:diet_guard_app/services/blob_store.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// [BlobStore] keeping one file per photo under `<documents>/images/`.
///
/// Keys are absolute paths, exactly as they were before photos went through
/// a store, so an already-installed phone keeps resolving the `imagePath` of
/// every photo it has ever attached.
class FileBlobStore implements BlobStore {
  /// Creates a store keeping its blobs under `<[documentsDirectory]>/images`.
  FileBlobStore(this.documentsDirectory);

  /// Directory whose `images/` subdirectory holds the photos.
  final Directory documentsDirectory;

  @override
  Future<String> put(String extension, Uint8List bytes) async {
    final imagesDir = Directory(p.join(documentsDirectory.path, 'images'));
    await imagesDir.create(recursive: true);
    final dest = File(p.join(imagesDir.path, '${const Uuid().v4()}$extension'));
    await dest.writeAsBytes(bytes);
    return dest.path;
  }

  @override
  Future<Uint8List?> get(String key) async {
    final file = File(key);
    if (!file.existsSync()) return null;
    try {
      return await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }
}

/// Opens the platform blob store (the app's documents directory).
// coverage:ignore-start
Future<BlobStore> openBlobStore() async =>
    FileBlobStore(await getApplicationDocumentsDirectory());
// coverage:ignore-end
