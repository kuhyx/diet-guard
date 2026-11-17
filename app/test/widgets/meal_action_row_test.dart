/// The 1A action row: photo, Claude, log; greyed until there is something.
library;

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/widgets/logged_meal_row.dart';
import 'package:diet_guard_app/widgets/meal_action_row.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../label_finders.dart';

Widget _row({
  ClaudeButtonState claude = ClaudeButtonState.idle,
  bool photo = false,
  bool canSend = true,
  bool canLog = true,
  List<String>? taps,
}) => MaterialApp(
  home: Scaffold(
    body: MealActionRow(
      claude: claude,
      photoAttached: photo,
      canSend: canSend,
      canLog: canLog,
      onPhoto: () => taps?.add('photo'),
      onGallery: () => taps?.add('gallery'),
      onRemovePhoto: () => taps?.add('remove'),
      onSend: () => taps?.add('send'),
      onLog: () => taps?.add('log'),
    ),
  ),
);

bool _enabled(WidgetTester tester, String label) {
  final button = tester.widget<FilledButton>(
    find.ancestor(of: byIconLabel(label), matching: find.byType(FilledButton)),
  );
  return button.onPressed != null;
}

void main() {
  testWidgets('tap is the camera, long press is the gallery', (tester) async {
    final taps = <String>[];
    await tester.pumpWidget(_row(taps: taps));
    await tester.tap(controlByLabel('Photo'));
    await tester.longPress(controlByLabel('Photo'));
    expect(taps, ['photo', 'gallery']);
  });

  testWidgets('send and log are greyed with nothing to send or log', (
    tester,
  ) async {
    await tester.pumpWidget(_row(canSend: false, canLog: false));
    expect(_enabled(tester, 'Ask Claude'), isFalse);
    expect(_enabled(tester, 'Log meal'), isFalse);
    expect(_enabled(tester, 'Photo'), isTrue);
  });

  testWidgets('an attached photo shows both badges and removes on the x', (
    tester,
  ) async {
    final taps = <String>[];
    await tester.pumpWidget(_row(photo: true, taps: taps));
    expect(byIconLabel('Photo attached'), findsOneWidget);
    await tester.tap(byIconLabel('Remove photo'));
    expect(taps, ['remove']);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('no badges without a photo', (tester) async {
    await tester.pumpWidget(_row());
    expect(byIconLabel('Photo attached'), findsNothing);
    expect(byIconLabel('Remove photo'), findsNothing);
  });

  for (final (state, label) in [
    (ClaudeButtonState.queued, 'Waiting for the PC'),
    (ClaudeButtonState.locked, 'Sync is locked'),
    (ClaudeButtonState.error, 'Claude failed'),
  ]) {
    testWidgets('$state paints its own glyph', (tester) async {
      await tester.pumpWidget(_row(claude: state));
      expect(byIconLabel(label), findsOneWidget);
      expect(byIconLabel('Ask Claude'), findsNothing);
    });
  }

  testWidgets('sending shows a spinner and blocks a second send', (
    tester,
  ) async {
    await tester.pumpWidget(_row(claude: ClaudeButtonState.sending));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final send = tester.widget<FilledButton>(find.byType(FilledButton).at(1));
    expect(send.onPressed, isNull);
  });

  testWidgets('a locked or failed button can be tapped to retry', (
    tester,
  ) async {
    final taps = <String>[];
    await tester.pumpWidget(_row(claude: ClaudeButtonState.error, taps: taps));
    await tester.tap(find.byType(FilledButton).at(1));
    expect(taps, ['send']);
  });

  testWidgets('a logged row names the meal and undoes on a 48 dp button', (
    tester,
  ) async {
    var undone = 0;
    const entry = FoodEntry(
      id: 'a',
      time: '2026-11-17T12:00:00',
      desc: 'kurczak z ryzem',
      grams: 300,
      kcal: 540,
      proteinG: 42,
      carbsG: 61,
      fatG: 9,
      source: 'claude',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoggedMealRow(
            meal: const LoggedMeal(entry, LoggedOrigin.claude),
            onUndo: () => undone++,
          ),
        ),
      ),
    );
    expect(find.text('kurczak z ryzem'), findsOneWidget);
    expect(find.text('540'), findsOneWidget);
    expect(byIconLabel('Undo'), findsOneWidget);
    final size = tester.getSize(find.byType(IconButton));
    expect(size.width, 48);
    expect(size.height, 48);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(byIconLabel('Undo'));
    expect(undone, 1);
  });

  testWidgets('the glyph tells where a logged meal came from', (tester) async {
    const entry = FoodEntry(
      id: 'a',
      time: 't',
      desc: 'x',
      grams: 1,
      kcal: 1,
      proteinG: 1,
      carbsG: 1,
      fatG: 1,
      source: 's',
    );
    for (final (origin, icon) in [
      (LoggedOrigin.claude, Icons.auto_awesome),
      (LoggedOrigin.catering, Icons.restaurant),
      (LoggedOrigin.local, Icons.check_circle),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LoggedMealRow(
              meal: const LoggedMeal(entry, LoggedOrigin.claude),
              onUndo: () {},
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LoggedMealRow(meal: LoggedMeal(entry, origin), onUndo: () {}),
          ),
        ),
      );
      expect(find.byIcon(icon), findsOneWidget);
    }
  });
}
