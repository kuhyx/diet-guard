// Shared Pixel 6a geometry helpers for the one-screen (no-scroll) tests.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pixel 6a: 1080x2400 px at 2.625 dpr, 132 px status bar, 63 px nav bar.
void usePixel6a(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(1080, 2400)
    ..devicePixelRatio = 2.625
    ..padding = const FakeViewPadding(top: 132, bottom: 63)
    ..viewPadding = const FakeViewPadding(top: 132, bottom: 63);
  addTearDown(tester.view.reset);
}

/// Largest `maxScrollExtent` among every vertical [Scrollable] on screen.
double maxVerticalExtent(WidgetTester tester) {
  var worst = 0.0;
  for (final element in find.byType(Scrollable).evaluate()) {
    final state = (element as StatefulElement).state as ScrollableState;
    if (state.widget.axis != Axis.vertical) continue;
    final extent = state.position.maxScrollExtent;
    if (extent > worst) worst = extent;
  }
  return worst;
}
