import 'package:diet_guard_app/ui/source_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'every stored source has its own glyph, unknown ones a neutral ring',
    () {
      expect(sourceIcon('manual'), Icons.edit);
      expect(sourceIcon('food bank'), Icons.restaurant_menu);
      expect(sourceIcon('catering'), Icons.local_shipping);
      expect(sourceIcon('legacy'), Icons.circle_outlined);
    },
  );

  testWidgets('the mark paints no text and speaks the stored source', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SourceMark('catering'))),
    );
    expect(find.byType(Text), findsNothing);
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.semanticLabel, 'catering');
  });
}
