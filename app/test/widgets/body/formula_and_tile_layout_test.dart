import 'package:diet_guard_app/models/workout_session.dart';
import 'package:diet_guard_app/widgets/body/activity_card.dart';
import 'package:diet_guard_app/widgets/body/body_tile_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../label_finders.dart';

Future<void> _pumpAt(WidgetTester tester, Size dp, Widget child) async {
  tester.view.physicalSize = dp;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

const _run = Session(
  day: '2026-09-27',
  kind: 'run',
  minutes: 30,
  km: 5,
  label: 'Morning run',
  source: 'pc',
);

bool _paintsFormulaWord(Widget w) =>
    w is Text &&
    const [
      'MET',
      'ACSM',
      'Per-km',
    ].any((word) => (w.data ?? '').contains(word));

void main() {
  testWidgets('activity formulas are icons; names only spoken', (tester) async {
    await _pumpAt(
      tester,
      const Size(360, 2400),
      const ActivityCard(
        sessions: [_run],
        weightKg: 70,
        exercise: {'MET': 300, 'ACSM': 310, 'Per-km': 320},
      ),
    );
    expect(find.byWidgetPredicate(_paintsFormulaWord), findsNothing);
    // A tooltip paints on long-press: none may carry a formula name.
    expect(find.byType(Tooltip), findsNothing);
    for (final name in ['MET', 'ACSM', 'Per-km']) {
      // One in the mean row, one in the session tile.
      expect(byIconLabel(name), findsNWidgets(2));
    }
    expect(find.text('300'), findsOneWidget);
    expect(find.text('310'), findsOneWidget);
    expect(find.text('320'), findsOneWidget);
    // Distinct glyphs, so the three are told apart without words.
    final glyphs = {
      for (final name in ['MET', 'ACSM', 'Per-km'])
        tester.widget<Icon>(byIconLabel(name).first).icon,
    };
    expect(glyphs, hasLength(3));
  });

  testWidgets('a fallback formula keeps its tilde marker', (tester) async {
    const lift = Session(
      day: '2026-09-27',
      kind: 'lift',
      minutes: 60,
      km: null,
      label: 'Lift',
      source: 'pc',
    );
    await _pumpAt(
      tester,
      const Size(360, 2400),
      const ActivityCard(sessions: [lift], weightKg: 70, exercise: null),
    );
    expect(find.textContaining('~'), findsNWidgets(2));
    expect(find.byWidgetPredicate(_paintsFormulaWord), findsNothing);
  });

  // A 360 dp phone, the Pixel's 411 dp, and a 4K web window.
  for (final size in const [Size(360, 800), Size(411, 800), Size(3840, 2160)]) {
    testWidgets('a weight tile value fits whole at $size', (tester) async {
      await _pumpAt(
        tester,
        size,
        Padding(
          padding: const EdgeInsets.all(16),
          child: BodyTileGrid(
            tiles: [
              BodyTileSpec(
                semanticLabel: 'Weight',
                icon: Icons.monitor_weight,
                value: '70.0 kg',
                builder: (_) => const SizedBox.shrink(),
              ),
              BodyTileSpec(
                semanticLabel: 'Body fat',
                icon: Icons.percent,
                value: '24.5 %',
                valueIcon: Icons.cake,
                builder: (_) => const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      );
      for (final value in ['70.0 kg', '24.5 %']) {
        final text = find.text(value);
        final paragraph = tester.renderObject<RenderParagraph>(text);
        expect(paragraph.didExceedMaxLines, isFalse, reason: value);
        final card = find.ancestor(of: text, matching: find.byType(Card));
        final inside = tester.getRect(card).inflate(0.5);
        // The painted rect (after FittedBox scaling) sits inside the tile.
        final painted = tester.getRect(text);
        expect(inside.contains(painted.topLeft), isTrue, reason: value);
        expect(inside.contains(painted.bottomRight), isTrue, reason: value);
        expect(painted.width, lessThanOrEqualTo(inside.width), reason: value);
        // The full text is laid out (no ellipsis clipping): its width is
        // the natural width of "70.0 kg" at this font.
        expect(paragraph.size.width, greaterThan(40), reason: value);
      }
    });
  }
}
