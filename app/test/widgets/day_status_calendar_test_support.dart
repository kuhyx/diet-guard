// Shared fixtures for the day_status_calendar widget tests.
//
// Split out of `day_status_calendar_test.dart` for the repo's 250-line cap.
// Public because the names now cross a file boundary -- a leading underscore
// is library-private in Dart.

import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The real app theme, not a bare default MaterialApp -- the widget under
// test reads its colors from Theme.of(context), so asserting against the
// same theme the app actually ships is what makes these assertions mean
// anything (a bare MaterialApp's own default colors would be arbitrary).
/// The real app theme the widget under test reads its colors from.
final ThemeData appTheme = buildAppTheme();
/// The app's status-color extension, for asserting per-day cell colors.
final AppStatusColors statusColors = appTheme.extension<AppStatusColors>()!;

/// Wraps [child] in a MaterialApp carrying the real app theme.
Widget wrapInApp(Widget child) => MaterialApp(
  theme: appTheme,
  home: Scaffold(body: child),
);

/// Returns the background color of the calendar cell showing [day].
Color colorOfDay(WidgetTester tester, String day) {
  final container = tester.widget<Container>(
    find.ancestor(of: find.text(day), matching: find.byType(Container)).first,
  );
  final decoration = container.decoration! as BoxDecoration;
  return decoration.color!;
}
