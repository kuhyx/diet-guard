/// The macro fields at the worst case: every value four digits wide.
///
/// "No overflow exception" proves nothing here -- a Row of Expanded fields
/// clips its text silently (see the row-expanded-clips-chips memory) -- so each
/// test measures the painted digits against the width the field really has.
library;

import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/macro_input_row.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// `flutter test` paints with Ahem, whose every glyph is one em wide. Roboto's
/// digits (the phone's font) are 0.5615 em, so measured widths are scaled down
/// to what the phone paints; without this the check would demand room no real
/// font needs.
const _ahemToRoboto = 0.5615;

const _worst = ['1250', '2400', '1234', '1234', '1234', '1234'];

Future<MacroControllers> _pump(WidgetTester tester, double width) async {
  tester.view
    ..physicalSize = Size(width * 2, 1600)
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final macros = MacroControllers();
  addTearDown(macros.dispose);
  final all = [
    macros.perGrams,
    macros.kcal,
    macros.protein,
    macros.carbs,
    macros.fat,
    macros.grams,
  ];
  for (var i = 0; i < all.length; i++) {
    all[i].text = _worst[i];
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: MacroInputRow(controllers: macros, compact: true),
        ),
      ),
    ),
  );
  return macros;
}

void main() {
  for (final width in [411.0, 360.0]) {
    group('at $width dp', () {
      testWidgets('four digits fit the field at 16 sp or more', (tester) async {
        await _pump(tester, width);
        final editables = tester.widgetList<EditableText>(
          find.byType(EditableText),
        );
        expect(editables, hasLength(6));
        for (final (i, editable) in editables.indexed) {
          expect(editable.style.fontSize, greaterThanOrEqualTo(16));
          final painter = TextPainter(
            text: TextSpan(text: _worst[i], style: editable.style),
            textDirection: TextDirection.ltr,
          )..layout();
          final room = tester.getSize(find.byType(EditableText).at(i)).width;
          final painted = painter.width * _ahemToRoboto;
          expect(
            painted,
            lessThanOrEqualTo(room),
            reason: '${_worst[i]} is clipped: $painted > $room',
          );
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('six fields sit in two rows of three', (tester) async {
        await _pump(tester, width);
        final tops = [
          for (var i = 0; i < 6; i++)
            tester.getTopLeft(find.byType(TextField).at(i)),
        ];
        expect(tops[0].dy, tops[1].dy);
        expect(tops[1].dy, tops[2].dy);
        expect(tops[3].dy, tops[4].dy);
        expect(tops[4].dy, tops[5].dy);
        expect(tops[3].dy, greaterThan(tops[0].dy));
        expect(tops[0].dx, lessThan(tops[1].dx));
      });
    });
  }
}
