/// Where a meal photo comes from. A photo is transient input to Claude: the
/// bytes live in memory for one send and are never stored, put on a
/// `FoodEntry` or synced.
library;

import 'dart:typed_data';

import 'package:diet_guard_app/services/meal_photo_cleanup.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

/// Which picker the user asked for.
enum PhotoOrigin {
  /// Take a new photo (a tap on the photo button).
  camera,

  /// Choose an existing one (a long press).
  gallery,
}

/// Hands back a photo as JPEG bytes, or null when the user backed out.
abstract interface class MealPhotoSource {
  /// Picks one photo from [origin].
  Future<Uint8List?> pick(PhotoOrigin origin);
}

/// The longest edge the photo is scaled to before it leaves the phone.
const mealPhotoMaxEdge = 1024.0;

/// [MealPhotoSource] on `image_picker`.
class ImagePickerPhotoSource implements MealPhotoSource {
  /// Creates the source; the three seams default to the real plugins.
  ImagePickerPhotoSource({
    @visibleForTesting Future<XFile?> Function(ImageSource source)? pickFile,
    @visibleForTesting Future<bool> Function()? requestCamera,
    @visibleForTesting Future<void> Function(String path)? discard,
  }) : _pickFile = pickFile ?? _pickWithPlugin,
       _requestCamera = requestCamera ?? _requestCameraPermission,
       _discard = discard ?? discardPickedFile;

  final Future<XFile?> Function(ImageSource source) _pickFile;
  final Future<bool> Function() _requestCamera;
  final Future<void> Function(String path) _discard;

  static Future<XFile?> _pickWithPlugin(ImageSource source) =>
      ImagePicker().pickImage(
        source: source,
        maxWidth: mealPhotoMaxEdge,
        maxHeight: mealPhotoMaxEdge,
        imageQuality: 85,
      );

  /// `permission_handler` has no web implementation; the browser asks for
  /// the camera itself when the picker opens.
  static Future<bool> _requestCameraPermission() async {
    if (kIsWeb) return true;
    return (await Permission.camera.request()).isGranted;
  }

  @override
  Future<Uint8List?> pick(PhotoOrigin origin) async {
    // The runtime permission comes first: launching the camera intent without
    // it fails on Android, and the failure names nothing.
    if (origin == PhotoOrigin.camera && !await _requestCamera()) return null;
    final file = await _pickFile(
      origin == PhotoOrigin.camera ? ImageSource.camera : ImageSource.gallery,
    );
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    // The plugin leaves the scaled JPEG in the app cache; the bytes are all
    // that is needed, so the file goes the moment they are read.
    await _discard(file.path);
    return bytes;
  }
}
