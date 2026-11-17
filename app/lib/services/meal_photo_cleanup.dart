/// Deletes the cache file `image_picker` leaves behind.
///
/// `dart:io` stays behind the platform seam (see `repo_invariants_test.dart`):
/// the io half deletes, the web half has no file to delete.
library;

export 'meal_photo_cleanup_io.dart'
    if (dart.library.js_interop) 'meal_photo_cleanup_web.dart';
