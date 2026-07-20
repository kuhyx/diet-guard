// Photo bytes went behind a BlobStore when the desktop target became a web
// build: Android keeps files, the browser keeps IndexedDB entries. These
// tests pin the file backend, which is what the phone actually runs.
import 'dart:io';
import 'dart:typed_data';

import 'package:diet_guard_app/services/blob_store_io.dart';
import 'package:diet_guard_app/services/photo_attach_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late FileBlobStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_blob_');
    store = FileBlobStore(tempDir);
  });

  tearDown(() async => tempDir.delete(recursive: true));

  test('put writes under images/ with the given extension', () async {
    final key = await store.put('.jpg', Uint8List.fromList([1, 2, 3]));

    expect(key, startsWith(p.join(tempDir.path, 'images')));
    expect(key, endsWith('.jpg'));
    expect(File(key).readAsBytesSync(), [1, 2, 3]);
  });

  test('put gives each blob its own key', () async {
    final first = await store.put('.jpg', Uint8List.fromList([1]));
    final second = await store.put('.jpg', Uint8List.fromList([2]));

    expect(first, isNot(second));
  });

  test('get returns the stored bytes', () async {
    final key = await store.put('.png', Uint8List.fromList([9, 8]));

    expect(await store.get(key), [9, 8]);
  });

  test('get returns null for a photo that is gone', () async {
    // The entry outlives its file when the user clears app storage; the UI
    // shows a broken-image icon rather than failing to build.
    expect(await store.get(p.join(tempDir.path, 'images', 'missing.jpg')), null);
  });

  test('get returns null when the path is not a readable file', () async {
    final directoryPath = p.join(tempDir.path, 'a_directory')..toString();
    Directory(directoryPath).createSync();

    expect(await store.get(directoryPath), null);
  });

  test('PhotoAttachService.readBytes reads through its store', () async {
    // Backs the web image widget, which cannot render from a path.
    PhotoAttachService.resetForTesting(store: store);
    addTearDown(PhotoAttachService.resetForTesting);
    final key = await store.put('.jpg', Uint8List.fromList([4, 5]));

    expect(await PhotoAttachService.instance.readBytes(key), [4, 5]);
  });
}
