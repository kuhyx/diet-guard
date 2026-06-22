import 'dart:io';

import 'package:diet_guard_app/services/photo_attach_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

/// Returns a fixed [XFile] (or null, to simulate a cancelled picker) without
/// touching any real platform channel.
class _FakeImagePickerPlatform extends ImagePickerPlatform {
  _FakeImagePickerPlatform(this._result);

  final XFile? _result;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => _result;
}

void main() {
  late Directory tempDir;
  late ImagePickerPlatform originalPlatform;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_photo_');
    originalPlatform = ImagePickerPlatform.instance;
    PhotoAttachService.resetForTesting(testDir: tempDir);
  });

  tearDown(() async {
    ImagePickerPlatform.instance = originalPlatform;
    PhotoAttachService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  test('copies the picked file into <documents>/images with a new name', () async {
    final source = File('${tempDir.path}/source.jpg')
      ..writeAsBytesSync([1, 2, 3, 4]);
    ImagePickerPlatform.instance = _FakeImagePickerPlatform(
      XFile(source.path),
    );

    final result = await PhotoAttachService.instance.pickAndStore(
      ImageSource.gallery,
    );

    expect(result, isNotNull);
    expect(result, startsWith('${tempDir.path}/images/'));
    expect(result, endsWith('.jpg'));
    expect(File(result!).readAsBytesSync(), [1, 2, 3, 4]);
  });

  test('returns null when the picker is cancelled', () async {
    ImagePickerPlatform.instance = _FakeImagePickerPlatform(null);

    final result = await PhotoAttachService.instance.pickAndStore(
      ImageSource.camera,
    );

    expect(result, isNull);
  });
}
