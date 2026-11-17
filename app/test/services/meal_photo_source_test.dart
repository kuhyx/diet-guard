/// The photo source: permission before camera, bytes only, cache file dropped.
library;

import 'dart:typed_data';

import 'package:diet_guard_app/services/meal_photo_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
  late List<ImageSource> picked;
  late List<String> discarded;
  late int permissionAsks;
  late bool granted;
  late XFile? next;

  ImagePickerPhotoSource source() => ImagePickerPhotoSource(
    pickFile: (s) async {
      picked.add(s);
      return next;
    },
    requestCamera: () async {
      permissionAsks++;
      return granted;
    },
    discard: (path) async => discarded.add(path),
  );

  setUp(() {
    picked = [];
    discarded = [];
    permissionAsks = 0;
    granted = true;
    next = XFile.fromData(jpeg, path: '/cache/pick.jpg');
  });

  test('the camera is not opened until permission is granted', () async {
    granted = false;
    expect(await source().pick(PhotoOrigin.camera), isNull);
    expect(permissionAsks, 1);
    expect(picked, isEmpty);
  });

  test('a granted camera pick returns the bytes and drops the file', () async {
    expect(await source().pick(PhotoOrigin.camera), jpeg);
    expect(picked, [ImageSource.camera]);
    expect(discarded, ['/cache/pick.jpg']);
  });

  test('the gallery needs no camera permission', () async {
    expect(await source().pick(PhotoOrigin.gallery), jpeg);
    expect(permissionAsks, 0);
    expect(picked, [ImageSource.gallery]);
  });

  test('backing out of the picker returns nothing', () async {
    next = null;
    expect(await source().pick(PhotoOrigin.gallery), isNull);
    expect(discarded, isEmpty);
  });

  test('photos are scaled to 1024 px', () {
    expect(mealPhotoMaxEdge, 1024);
  });
}
