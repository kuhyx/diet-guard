/// A local log while a Claude request waits withdraws it, and the request id
/// the screen makes is one the relay serves.
library;

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/claude_relay_client.dart';
import 'package:diet_guard_app/services/claude_relay_fake.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../label_finders.dart';
import 'log_meal_test_support.dart';

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

  setUp(() async {
    restore = await isolateLogScreenState();
    relay = FakeClaudeRelayClient();
  });
  tearDown(() => restore());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: LogMealScreen(relay: relay)));
    await settle(tester);
  }

  testWidgets('the request id is a ULID and the mode follows due mode', (
    tester,
  ) async {
    pinLogMealClock(13);
    await tester.runAsync(() async {
      await open(tester);
      await tester.enterText(find.byType(TextField).at(0), 'kurczak');
      await settle(tester);
      await tester.tap(controlByLabel('Ask Claude'));
      await tester.pump();
      final sent = relay.sent.single;
      expect(
        RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$').hasMatch(sent.requestId),
        isTrue,
      );
      expect(sent.mode, ClaudeRelayMode.due);
    });
  });

  for (final claimed in [false, true]) {
    testWidgets('a local log while queued withdraws the request '
        '(${claimed ? 'already claimed' : 'unclaimed'})', (tester) async {
      pinLogMealClock(13);
      relay.cancelResult = !claimed;
      await tester.runAsync(() async {
        await open(tester);
        await tester.enterText(find.byType(TextField).at(0), 'kurczak');
        await settle(tester);
        await tester.tap(controlByLabel('Ask Claude'));
        await tester.pump();
        relay.emit(const ClaudeRelayQueued());
        await settle(tester);

        await tester.tap(controlByLabel('Log meal'));
        await settle(tester);

        expect(relay.cancelled, [relay.sent.single.requestId]);
        expect(byIconLabel('Ask Claude'), findsOneWidget);
        expect(await LogStorageService.instance.todayEntries(), hasLength(1));

        // Claimed: the PC still logs it, so the stream stays open and the
        // duplicate shows with an undo instead of arriving unseen.
        relay.emit(
          ClaudeRelayLogged(
            _claudeEntry(claudeEntryId(relay.sent.single.requestId)),
          ),
        );
        await settle(tester);
        final live = await LogStorageService.instance.todayEntries();
        expect(live, hasLength(claimed ? 2 : 1));
      });
    });
  }
}
