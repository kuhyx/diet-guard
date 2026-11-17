/// The sparkle button and the photo button on the log screen.
library;

import 'dart:typed_data';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/claude_relay_client.dart';
import 'package:diet_guard_app/services/claude_relay_fake.dart';
import 'package:diet_guard_app/services/log_entry_lookup.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_photo_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../label_finders.dart';
import 'log_meal_test_support.dart';

class _Photos implements MealPhotoSource {
  final List<PhotoOrigin> asked = [];
  final Uint8List bytes = Uint8List.fromList([1, 2, 3]);

  @override
  Future<Uint8List?> pick(PhotoOrigin origin) async {
    asked.add(origin);
    return bytes;
  }
}

FoodEntry _claudeEntry(String id) => FoodEntry(
  id: id,
  time: DateTime.now().toIso8601String().substring(0, 19),
  desc: 'kurczak z ryzem',
  grams: 300,
  kcal: 540,
  proteinG: 42,
  carbsG: 61,
  fatG: 9,
  source: 'claude',
  slotMinute: 480,
);

void main() {
  late Future<void> Function() restore;
  late FakeClaudeRelayClient relay;
  late _Photos photos;

  setUp(() async {
    restore = await isolateLogScreenState();
    relay = FakeClaudeRelayClient();
    photos = _Photos();
  });
  tearDown(() => restore());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LogMealScreen(relay: relay, photos: photos),
      ),
    );
    await settle(tester);
  }

  bool sparkleEnabled(WidgetTester tester) =>
      tester
          .widget<FilledButton>(
            find.ancestor(
              of: find.byWidgetPredicate(
                (w) =>
                    w is Icon &&
                    (w.semanticLabel == 'Ask Claude' ||
                        w.icon == Icons.hourglass_top ||
                        w.icon == Icons.lock ||
                        w.icon == Icons.error_outline),
              ),
              matching: find.byType(FilledButton),
            ),
          )
          .onPressed !=
      null;

  testWidgets('the sparkle is greyed until there is text or a photo', (
    tester,
  ) async {
    pinLogMealClock(13);
    await tester.runAsync(() async {
      await open(tester);
      expect(sparkleEnabled(tester), isFalse);
      await tester.enterText(find.byType(TextField).at(0), 'kurczak');
      await settle(tester);
      expect(sparkleEnabled(tester), isTrue);
    });
  });

  testWidgets('a photo alone enables the sparkle; tap camera, hold gallery', (
    tester,
  ) async {
    pinLogMealClock(13);
    await tester.runAsync(() async {
      await open(tester);
      // Inside runAsync the recognizer's timer is real, so wait in real time.
      final press = await tester.startGesture(
        tester.getCenter(controlByLabel('Photo')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await press.up();
      await settle(tester);
      expect(photos.asked, [PhotoOrigin.gallery]);
      await tester.tap(byIconLabel('Remove photo'));
      await settle(tester);
      await tester.tap(controlByLabel('Photo'));
      await settle(tester);
      expect(photos.asked, [PhotoOrigin.gallery, PhotoOrigin.camera]);
      expect(sparkleEnabled(tester), isTrue);
      expect(byIconLabel('Photo attached'), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      await tester.tap(byIconLabel('Remove photo'));
      await settle(tester);
      expect(sparkleEnabled(tester), isFalse);


    });
  });

  testWidgets('a send carries the text, photo and the oldest due slot', (
    tester,
  ) async {
    pinLogMealClock(13); // 08:00 and 12:00 are due
    await tester.runAsync(() async {
      await open(tester);
      await tester.tap(controlByLabel('Photo'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(0), '  kurczak  ');
      await settle(tester);
      await tester.tap(controlByLabel('Ask Claude'));
      await tester.pump();

      final sent = relay.sent.single;
      expect(sent.text, 'kurczak');
      expect(sent.photoJpeg, photos.bytes);
      expect(sent.slotMinute, 480);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  testWidgets('queued, then logged: the row shows and undo tombstones it', (
    tester,
  ) async {
    pinLogMealClock(13);
    await tester.runAsync(() async {
      await open(tester);
      await tester.enterText(find.byType(TextField).at(0), 'kurczak');
      await settle(tester);
      await tester.tap(controlByLabel('Ask Claude'));
      await tester.pump();
      relay.emit(const ClaudeRelayQueued());
      await settle(tester);
      expect(byIconLabel('Waiting for the PC'), findsOneWidget);

      final id = relay.sent.single.requestId;
      relay.emit(ClaudeRelayLogged(_claudeEntry(id)));
      await settle(tester);

      expect(find.text('kurczak z ryzem'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome), findsWidgets);
      expect((await LogStorageService.instance.todayEntries()).single.id, id);
      // The form reset, and the photo is gone with the send.
      expect(
        tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
        '',
      );

      await tester.tap(byIconLabel('Undo'));
      await settle(tester);
      expect(await LogStorageService.instance.todayEntries(), isEmpty);
      expect((await LogStorageService.instance.findEntry(id))!.deleted, isTrue);
      expect(find.text('kurczak z ryzem'), findsNothing);
    });
  });

  for (final (event, glyph) in [
    (const ClaudeRelayLocked(), Icons.lock),
    (const ClaudeRelayFailed('boom'), Icons.error_outline),
  ]) {
    testWidgets('$event paints its glyph and keeps the text', (tester) async {
      pinLogMealClock(13);
      await tester.runAsync(() async {
        await open(tester);
        await tester.enterText(find.byType(TextField).at(0), 'kurczak');
        await settle(tester);
        await tester.tap(controlByLabel('Ask Claude'));
        await tester.pump();
        relay.emit(event);
        await settle(tester);
        expect(find.byIcon(glyph), findsOneWidget);
        expect(find.text('kurczak'), findsOneWidget);
        expect(sparkleEnabled(tester), isTrue); // a tap retries
      });
    });
  }
}
