// Guard: a catering fetch / fill reports with a glyph and a dish count; its
// sentence is only the spoken label.

import 'package:diet_guard_app/screens/log_meal_fill_mixin.dart';
import 'package:diet_guard_app/services/kuchnia_spread.dart';
import 'package:diet_guard_app/ui/cues.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'label_finders.dart';
import 'no_words_support.dart';

void main() {
  group('fillCue', () {
    test('nothing to fill paints a warning and 0', () {
      final cue = fillCue((
        message: 'No catering delivery today.',
        written: const <SlottedDish>[],
      ), armed: 0);
      expect(cue.kind, CueKind.warn);
      expect(cue.count, 0);
      expect(cue.label, 'No catering delivery today.');
    });

    test('a proposal paints its armed count', () {
      final cue = fillCue((
        message: 'Will log 3',
        written: const <SlottedDish>[],
      ), armed: 3);
      expect((cue.kind, cue.count), (CueKind.info, 3));
    });
  });

  testWidgets('a counted cue paints only the glyph and the number', (
    tester,
  ) async {
    final state = CueState.next(
      null,
      CueKind.ok,
      'Logged 4 catering dishes.',
      4,
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: state.widget)));
    expect(find.text('4'), findsOneWidget);
    expect(cueLabelled('Logged 4 catering dishes.'), findsOneWidget);
    expectNoWords(tester, minStrings: 2, where: 'fill cue');
  });

  testWidgets('the delivery snackbar paints the dish glyph and 0', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCueSnack(
                context,
                kind: CueKind.warn,
                semanticLabel: 'No delivery today.',
                icon: Icons.restaurant,
                count: 0,
              ),
              child: const Icon(Icons.local_shipping),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byIcon(Icons.restaurant), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
    expectNoWords(tester, minStrings: 3, where: 'delivery snack');
  });
}
