/// Picks a photo and copies it into permanent phone-local storage.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Wraps [ImagePicker] and persists the result under the app's documents
/// directory, so the returned path survives after the picker's own
/// (possibly cache-cleared) temp file is gone.
///
/// Photos are phone-local only: per the sync plan (Milestone 3), a logged
/// entry's `imagePath` is stripped before push and never read from a pulled
/// remote copy, so no storage here needs to be sync-aware.
class PhotoAttachService {
  PhotoAttachService._(this._testDir);

  static PhotoAttachService _instance = PhotoAttachService._(null);

  /// The singleton instance.
  static PhotoAttachService get instance => _instance;

  final Directory? _testDir;

  /// Redirects where picked photos are copied to, so a test never touches
  /// the real documents directory. Pass null to restore default behavior.
  @visibleForTesting
  static void resetForTesting({Directory? testDir}) {
    _instance = PhotoAttachService._(testDir);
  }

  /// Opens [source] (camera or gallery), and on a successful pick, copies
  /// the image into `<app documents>/images/<uuid>.<ext>`.
  ///
  /// Returns the new permanent path, or null if the user cancelled the
  /// picker.
  Future<String?> pickAndStore(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source);
    if (picked == null) return null;
    final docsDir = _testDir ?? await getApplicationDocumentsDirectory();
    final imagesDir = Directory(p.join(docsDir.path, 'images'));
    await imagesDir.create(recursive: true);
    final ext = p.extension(picked.path);
    final dest = p.join(imagesDir.path, '${const Uuid().v4()}$ext');
    await File(picked.path).copy(dest);
    return dest;
  }
}
