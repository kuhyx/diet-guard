/// A meal photo is transient input to Claude, never data.
///
/// Photos came back on 2026-11-17 as input to the Claude relay only (the
/// earlier removal still stands for blob stores and the `/blobs/` route). A
/// device-local attachment would break the one-source-of-truth rule, so these
/// assertions are structural: a new field or file cannot slip an image into an
/// entry, a store or the sync wire unnoticed.
library;

import 'dart:io';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/meal_component.dart';
import 'package:flutter_test/flutter_test.dart';

Directory get _appDir {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) fail('could not locate app/');
    dir = parent;
  }
  return dir;
}

List<File> _dartFilesIn(String relative) =>
    Directory('${_appDir.path}/$relative')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

void main() {
  group('a meal photo is transient input to Claude, never data', () {
    const pickerHome = 'services/meal_photo_source.dart';
    const photoFiles = {
      'services/meal_photo_source.dart',
      'services/meal_photo_cleanup.dart',
      'services/meal_photo_cleanup_io.dart',
      'services/meal_photo_cleanup_web.dart',
      'services/claude_relay_client.dart',
      'services/claude_relay_fake.dart',
    };
    String relative(File f) => f.path.split('/app/lib/').last;

    test('image_picker is imported by the photo source alone', () {
      final offenders = [
        for (final file in _dartFilesIn('lib'))
          if (relative(file) != pickerHome &&
              file.readAsStringSync().contains('package:image_picker/'))
            relative(file),
      ];
      expect(offenders, isEmpty);
    });

    test('image bytes stay out of entries, storage and sync', () {
      final banned = RegExp(
        r'Uint8List|photo|jpeg|jpg|base64',
        caseSensitive: false,
      );
      final offenders = [
        for (final file in _dartFilesIn('lib'))
          if (!photoFiles.contains(relative(file)) &&
              (relative(file).startsWith('models/') ||
                  relative(file).contains('sync_') ||
                  relative(file).contains('document_store') ||
                  relative(file).contains('log_storage') ||
                  relative(file).contains('log_entry') ||
                  relative(file).contains('foodbank')) &&
              banned.hasMatch(file.readAsStringSync()))
            relative(file),
      ];
      expect(
        offenders,
        isEmpty,
        reason:
            'A photo (or its bytes) reached a model, a store or the sync '
            'wire. Photos are transient input to the Claude relay only.',
      );
    });

    test('a FoodEntry syncs a fixed set of keys, none of them an image', () {
      const entry = FoodEntry(
        id: 'a',
        time: '2026-11-17T08:00:00',
        desc: 'x',
        grams: 1,
        kcal: 1,
        proteinG: 1,
        carbsG: 1,
        fatG: 1,
        source: 'claude',
        slotMinute: 435,
        components: [
          MealComponent(
            name: 'c',
            kcal: 1,
            proteinG: 1,
            carbsG: 1,
            fatG: 1,
            grams: 1,
          ),
        ],
        deleted: true,
      );
      expect(entry.toSyncJson().keys.toSet(), {
        'id',
        'time',
        'desc',
        'grams',
        'kcal',
        'protein_g',
        'carbs_g',
        'fat_g',
        'source',
        'slot',
        'slot_min',
        'components',
        'deleted',
      });
    });

    test('the photo is only ever picked into memory', () {
      final source = File('${_appDir.path}/lib/$pickerHome').readAsStringSync();
      expect(source.contains('readAsBytes'), isTrue);
      for (final banned in [
        'path_provider',
        'writeAsBytes',
        'getApplication',
      ]) {
        expect(source.contains(banned), isFalse, reason: banned);
      }
    });

    test('the camera permission is declared for the picker', () {
      final manifest = File(
        '${_appDir.path}/android/app/src/main/AndroidManifest.xml',
      );
      expect(
        manifest.readAsStringSync().contains('android.permission.CAMERA'),
        isTrue,
      );
    });
  });
}
