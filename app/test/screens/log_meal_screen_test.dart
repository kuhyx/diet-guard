import 'dart:io';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/food_bank_screen.dart';
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/screens/history_screen.dart';
import 'package:diet_guard_app/screens/meal_builder_screen.dart';
import 'package:diet_guard_app/screens/photo_viewer_screen.dart';
import 'package:diet_guard_app/screens/settings_screen.dart';
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

/// A minimal valid 1x1 transparent PNG, so the thumbnail preview can decode
/// it as a real image instead of throwing on bogus bytes.
const List<int> _onePixelPng = [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x62,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

void main() {
  late Directory tempDir;
  late ImagePickerPlatform originalImagePickerPlatform;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_screen_');
    LogStorageService.resetForTesting(testDir: tempDir);
    FoodBankService.resetForTesting(testDir: tempDir);
    PhotoAttachService.resetForTesting(testDir: tempDir);
    originalImagePickerPlatform = ImagePickerPlatform.instance;
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    PhotoAttachService.resetForTesting();
    ImagePickerPlatform.instance = originalImagePickerPlatform;
    await tempDir.delete(recursive: true);
  });

  final logMealButton = find.byTooltip('Log meal');

  // The screen's button handlers and description-field listener trigger
  // real `dart:io` file I/O as fire-and-forget Futures that Flutter's frame
  // scheduler does not track -- pumpAndSettle() can return *before* that
  // I/O (and its eventual setState) actually finishes. Every interaction
  // that can reach a service call therefore runs inside a single
  // tester.runAsync() per test, with a short real delay before each
  // pumpAndSettle() to let the in-flight I/O actually complete first.
  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  testWidgets('the history icon navigates to HistoryScreen', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.history));
      await settle(tester);

      expect(find.byType(HistoryScreen), findsOneWidget);
    });
  });

  testWidgets('the settings icon navigates to SettingsScreen', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      // SettingsScreen briefly shows a perpetually-animating
      // CircularProgressIndicator while its settings load; pumpAndSettle
      // never settles against that, so pump explicit frames instead (see
      // history_screen_test.dart's note on the same pitfall).
      await tester.tap(find.byIcon(Icons.settings));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();

      expect(find.byType(SettingsScreen), findsOneWidget);
    });
  });

  testWidgets('logging a manually-typed meal persists it as source manual', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      await tester.enterText(find.byType(TextField).at(0), 'toast');
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(2), '150');
      await tester.enterText(find.byType(TextField).at(3), '5');
      await tester.enterText(find.byType(TextField).at(4), '20');
      await tester.enterText(find.byType(TextField).at(5), '3');
      await settle(tester);

      await tester.ensureVisible(logMealButton);
      await tester.tap(logMealButton);
      await settle(tester);

      expect(find.text('Logged "toast".'), findsOneWidget);
      final entries = await LogStorageService.instance.todayEntries();
      expect(entries.single.source, 'manual');
      expect(entries.single.kcal, 150);
    });
  });

  testWidgets('refuses to log with an empty description', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      await tester.ensureVisible(logMealButton);
      await tester.tap(logMealButton);
      await settle(tester);

      expect(find.text('Type what you ate first.'), findsOneWidget);
      expect(await LogStorageService.instance.todayEntries(), isEmpty);
    });
  });

  testWidgets(
    'per-grams and amount-eaten fields scale macros to the eaten portion',
    (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
        await settle(tester);

        await tester.enterText(find.byType(TextField).at(0), 'label food');
        await settle(tester);
        await tester.enterText(find.byType(TextField).at(1), '100');
        await tester.enterText(find.byType(TextField).at(2), '200');
        await tester.enterText(find.byType(TextField).at(3), '10');
        await tester.enterText(find.byType(TextField).at(4), '20');
        await tester.enterText(find.byType(TextField).at(5), '5');
        await tester.enterText(find.byType(TextField).at(6), '150');
        await settle(tester);

        await tester.ensureVisible(logMealButton);
        await tester.tap(logMealButton);
        await settle(tester);

        final entry = (await LogStorageService.instance.todayEntries()).single;
        expect(entry.kcal, 300);
        expect(entry.proteinG, 15);
        expect(entry.carbsG, 30);
        expect(entry.fatG, 7.5);
        expect(entry.grams, 150);
      });
    },
  );

  testWidgets(
    'selecting a food-bank suggestion stamps source food bank, but '
    'editing a macro afterward reverts it to manual',
    (tester) async {
      await tester.runAsync(() async {
        const seed = FoodEntry(
          id: 'seed-1',
          time: '2026-06-01T08:00:00+02:00',
          desc: 'seeded food',
          grams: 100,
          kcal: 250,
          proteinG: 10,
          carbsG: 30,
          fatG: 8,
          source: 'manual',
        );
        await FoodBankService.instance.rebuildAndPersist({
          '2026-06-01': [seed],
        });

        await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
        await settle(tester);

        // The empty-query suggestion list shows the only banked food.
        await tester.tap(find.text('seeded food · 250 kcal'));
        await settle(tester);
        await tester.ensureVisible(logMealButton);
        await tester.tap(logMealButton);
        await settle(tester);

        final firstEntry =
            (await LogStorageService.instance.todayEntries()).single;
        expect(firstEntry.source, 'food bank');
        expect(firstEntry.kcal, 250);

        await tester.tap(find.text('seeded food · 250 kcal'));
        await settle(tester);
        await tester.enterText(find.byType(TextField).at(2), '999');
        await settle(tester);
        await tester.ensureVisible(logMealButton);
        await tester.tap(logMealButton);
        await settle(tester);

        final secondEntry =
            (await LogStorageService.instance.todayEntries()).last;
        expect(secondEntry.source, 'manual');
        expect(secondEntry.kcal, 999);
      });
    },
  );

  testWidgets(
    'attaching a photo persists its path on the logged entry, and removing '
    'it before logging clears it again',
    (tester) async {
      await tester.runAsync(() async {
        // A real (1x1, transparent) PNG, not an arbitrary byte sequence --
        // the thumbnail preview decodes this file as an actual image, and a
        // bogus payload throws inside the image codec rather than failing
        // cleanly.
        final source = File('${tempDir.path}/source.jpg')
          ..writeAsBytesSync(_onePixelPng);
        ImagePickerPlatform.instance = _FakeImagePickerPlatform(
          XFile(source.path),
        );

        await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
        await settle(tester);

        await tester.enterText(find.byType(TextField).at(0), 'snack');
        await settle(tester);

        await tester.tap(find.byTooltip('Attach photo'));
        await settle(tester);
        await tester.tap(find.text('Choose from gallery'));
        await settle(tester);

        expect(find.byTooltip('Remove photo'), findsOneWidget);

        await tester.ensureVisible(logMealButton);
        await tester.tap(logMealButton);
        await settle(tester);

        final entry = (await LogStorageService.instance.todayEntries()).single;
        expect(entry.imagePath, isNotNull);
        expect(entry.imagePath, startsWith('${tempDir.path}/images/'));
        expect(File(entry.imagePath!).readAsBytesSync(), _onePixelPng);

        await tester.enterText(find.byType(TextField).at(0), 'snack two');
        await settle(tester);
        await tester.tap(find.byTooltip('Attach photo'));
        await settle(tester);
        await tester.tap(find.text('Choose from gallery'));
        await settle(tester);
        await tester.tap(find.byTooltip('Remove photo'));
        await settle(tester);
        await tester.ensureVisible(logMealButton);
        await tester.tap(logMealButton);
        await settle(tester);

        final secondEntry =
            (await LogStorageService.instance.todayEntries()).last;
        expect(secondEntry.imagePath, isNull);
      });
    },
  );

  testWidgets('tapping the attached-photo thumbnail opens the full viewer', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final source = File('${tempDir.path}/source.jpg')
        ..writeAsBytesSync(_onePixelPng);
      ImagePickerPlatform.instance = _FakeImagePickerPlatform(
        XFile(source.path),
      );

      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      await tester.tap(find.byTooltip('Attach photo'));
      await settle(tester);
      await tester.tap(find.text('Choose from gallery'));
      await settle(tester);

      await tester.tap(find.byType(Image));
      await settle(tester);

      expect(find.byType(PhotoViewerScreen), findsOneWidget);
    });
  });

  testWidgets('food bank icon navigates to FoodBankScreen', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.restaurant_menu));
      await settle(tester);

      expect(find.byType(FoodBankScreen), findsOneWidget);
    });
  });

  testWidgets('build meal button navigates to MealBuilderScreen', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      await tester.ensureVisible(find.byTooltip('Build a multi-item meal'));
      await tester.tap(find.byTooltip('Build a multi-item meal'));
      await settle(tester);

      expect(find.byType(MealBuilderScreen), findsOneWidget);
    });
  });

  testWidgets('logged slot chip renders check-icon avatar', (tester) async {
    await tester.runAsync(() async {
      final now = DateTime.now();
      final dateKey =
          '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final at8 = DateTime(now.year, now.month, now.day, 8);

      await LogStorageService.instance.writeLog({
        dateKey: [
          FoodEntry(
            id: 'slot-seed',
            time: at8.toIso8601String(),
            desc: 'breakfast',
            grams: 100,
            kcal: 300,
            proteinG: 10,
            carbsG: 40,
            fatG: 5,
            source: 'manual',
            slot: 8,
          ),
        ],
      });

      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      // The 08:00 slot is logged — its ChoiceChip has a check-icon avatar.
      expect(find.byIcon(Icons.check), findsWidgets);
    });
  });

  testWidgets('tapping a slot chip selects it', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      // Tap the 08:00 chip to force _selectedSlot = 8.
      await tester.tap(find.text('08:00'));
      await settle(tester);

      final chip = tester.widget<ChoiceChip>(
        find.ancestor(
          of: find.text('08:00'),
          matching: find.byType(ChoiceChip),
        ),
      );
      expect(chip.selected, isTrue);
    });
  });

  testWidgets('navigating to MealBuilderScreen and back refreshes slots', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      // Open MealBuilderScreen.
      await tester.ensureVisible(find.byTooltip('Build a multi-item meal'));
      await tester.tap(find.byTooltip('Build a multi-item meal'));
      await settle(tester);

      expect(find.byType(MealBuilderScreen), findsOneWidget);

      // Pop back — triggers _onBuildMeal's await _refreshSlots() (line 213).
      await tester.tap(find.byTooltip('Back'));
      await settle(tester);

      expect(find.byType(LogMealScreen), findsOneWidget);
    });
  });
}
