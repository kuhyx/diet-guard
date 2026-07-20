import 'dart:io';

import 'package:diet_guard_app/services/blob_store_io.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/screens/meal_builder_screen.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/photo_attach_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

/// Returns a fixed [XFile] without touching any real platform channel.
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
  late ImagePickerPlatform originalImagePickerPlatform;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_builder_');
    LogStorageService.resetForTesting(store: FileDocumentStore(tempDir));
    FoodBankService.resetForTesting(store: FileDocumentStore(tempDir));
    PhotoAttachService.resetForTesting(store: FileBlobStore(tempDir));
    originalImagePickerPlatform = ImagePickerPlatform.instance;
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    PhotoAttachService.resetForTesting();
    ImagePickerPlatform.instance = originalImagePickerPlatform;
    await tempDir.delete(recursive: true);
  });

  final addItemButton = find.widgetWithText(ElevatedButton, 'Add item');
  final logMealButton = find.widgetWithText(ElevatedButton, 'Log meal');

  // See log_meal_screen_test.dart: "Log meal" triggers real dart:io File
  // writes as an unawaited Future Flutter's scheduler doesn't track, so a
  // short real delay before settling is needed in addition to runAsync().
  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  testWidgets('refuses to log a meal with no items added', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: MealBuilderScreen()));
      await settle(tester);

      await tester.tap(logMealButton);
      await settle(tester);

      expect(find.text('Add at least one item first.'), findsOneWidget);
    });
  });

  testWidgets(
    'adds an item with per/ate scaling applied, then logs the composite '
    'meal with full per-component macros',
    (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          const MaterialApp(home: MealBuilderScreen()),
        );
        await settle(tester);

        // Field order: [0] meal name, [1] item name, [2] per (g),
        // [3] kcal, [4] protein, [5] carbs, [6] fat, [7] ate (g).
        await tester.enterText(find.byType(TextField).at(1), 'rice');
        await tester.enterText(find.byType(TextField).at(2), '100');
        await tester.enterText(find.byType(TextField).at(3), '200');
        await tester.enterText(find.byType(TextField).at(4), '4');
        await tester.enterText(find.byType(TextField).at(5), '44');
        await tester.enterText(find.byType(TextField).at(6), '1');
        await tester.enterText(find.byType(TextField).at(7), '150');
        await settle(tester);
        await tester.tap(addItemButton);
        await settle(tester);

        expect(find.textContaining('So far (1)'), findsOneWidget);
        expect(find.textContaining('300 kcal'), findsOneWidget);

        await tester.enterText(find.byType(TextField).at(1), 'chicken');
        await tester.enterText(find.byType(TextField).at(3), '165');
        await tester.enterText(find.byType(TextField).at(4), '31');
        await tester.enterText(find.byType(TextField).at(5), '0');
        await tester.enterText(find.byType(TextField).at(6), '4');
        await settle(tester);
        await tester.tap(addItemButton);
        await settle(tester);

        await tester.tap(logMealButton);
        await settle(tester);

        final entry = (await LogStorageService.instance.todayEntries()).single;
        expect(entry.source, 'meal');
        expect(entry.kcal, 465); // 300 (scaled rice) + 165 (chicken)
        expect(entry.components, hasLength(2));
        final rice = entry.components!.firstWhere((c) => c.name == 'rice');
        expect(rice.kcal, 300);
        expect(rice.proteinG, 6);
        expect(rice.carbsG, 66);
        expect(rice.fatG, 1.5);
        expect(rice.grams, 150);
      });
    },
  );

  testWidgets(
    'attaching a photo to a composite meal persists its path on the logged '
    'entry',
    (tester) async {
      await tester.runAsync(() async {
        final source = File('${tempDir.path}/source.jpg')
          ..writeAsBytesSync([1, 2, 3]);
        ImagePickerPlatform.instance = _FakeImagePickerPlatform(
          XFile(source.path),
        );

        await tester.pumpWidget(
          const MaterialApp(home: MealBuilderScreen()),
        );
        await settle(tester);

        await tester.enterText(find.byType(TextField).at(1), 'soup');
        await tester.enterText(find.byType(TextField).at(3), '120');
        await settle(tester);
        await tester.tap(addItemButton);
        await settle(tester);

        await tester.ensureVisible(find.text('Attach photo'));
        await tester.tap(find.text('Attach photo'));
        await settle(tester);
        await tester.tap(find.text('Choose from gallery'));
        await settle(tester);

        await tester.ensureVisible(logMealButton);
        await tester.tap(logMealButton);
        await settle(tester);

        final entry = (await LogStorageService.instance.todayEntries()).single;
        expect(entry.imagePath, isNotNull);
        expect(entry.imagePath, startsWith('${tempDir.path}/images/'));
      });
    },
  );

  testWidgets(
    'logged meal uses provided name when name field is non-empty (line 73)',
    (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(const MaterialApp(home: MealBuilderScreen()));
        await settle(tester);

        // Enter a meal name in field at(0), item in at(1), kcal in at(3).
        await tester.enterText(find.byType(TextField).at(0), 'Sunday dinner');
        await tester.enterText(find.byType(TextField).at(1), 'pasta');
        await tester.enterText(find.byType(TextField).at(3), '400');
        await settle(tester);
        await tester.tap(addItemButton);
        await settle(tester);

        await tester.ensureVisible(logMealButton);
        await tester.tap(logMealButton);
        await settle(tester);

        final entry = (await LogStorageService.instance.todayEntries()).single;
        expect(entry.desc, equals('Sunday dinner'));
      });
    },
  );

  testWidgets(
    'Add item with empty description shows error status (line 46)',
    (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(const MaterialApp(home: MealBuilderScreen()));
        await settle(tester);

        // Tap "Add item" without entering any description.
        await tester.tap(addItemButton);
        await settle(tester);

        expect(
          find.text('Type the item first, then add it.'),
          findsOneWidget,
        );
      });
    },
  );

  testWidgets(
    'logging a meal with empty name field defaults name to "meal" (line 73)',
    (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(const MaterialApp(home: MealBuilderScreen()));
        await settle(tester);

        // Add one item (name field intentionally left empty).
        await tester.enterText(find.byType(TextField).at(1), 'rice');
        await tester.enterText(find.byType(TextField).at(3), '200');
        await settle(tester);
        await tester.tap(addItemButton);
        await settle(tester);

        // Leave meal name field empty, then log — name defaults to 'meal'.
        await tester.ensureVisible(logMealButton);
        await tester.tap(logMealButton);
        await settle(tester);

        final entry = (await LogStorageService.instance.todayEntries()).single;
        expect(entry.desc, equals('meal'));
      });
    },
  );

  testWidgets(
    'photo attach sheet "Take a photo" choice covers camera onTap (lines 42-43)',
    (tester) async {
      await tester.runAsync(() async {
        final fakePhoto = File('${tempDir.path}/fake_camera.jpg')
          ..createSync()
          ..writeAsBytesSync([0xFF, 0xD8, 0xFF]);
        ImagePickerPlatform.instance = _FakeImagePickerPlatform(
          XFile(fakePhoto.path),
        );
        await tester.pumpWidget(const MaterialApp(home: MealBuilderScreen()));
        await settle(tester);

        await tester.enterText(find.byType(TextField).at(1), 'salad');
        await tester.enterText(find.byType(TextField).at(3), '100');
        await settle(tester);
        await tester.tap(addItemButton);
        await settle(tester);

        await tester.ensureVisible(find.text('Attach photo'));
        await tester.tap(find.text('Attach photo'));
        await settle(tester);
        // Tap "Take a photo" → triggers camera onTap (lines 42-43).
        await tester.tap(find.text('Take a photo'));
        await settle(tester);

        await tester.ensureVisible(logMealButton);
        await tester.tap(logMealButton);
        await settle(tester);

        final entry = (await LogStorageService.instance.todayEntries()).single;
        expect(entry.imagePath, isNotNull);
      });
    },
  );
}
