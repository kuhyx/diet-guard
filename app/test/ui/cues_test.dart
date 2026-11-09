/// Text-free status cues: kind -> icon/tint, haptics, snackbar undo.
library;

import 'package:diet_guard_app/ui/cues.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../label_finders.dart';

void main() {
  final haptics = <String>[];

  setUp(() {
    haptics.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String);
          }
          return null;
        });
  });

  Widget host(Widget child, {bool reduceMotion = false}) => MaterialApp(
    theme: buildAppTheme(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Scaffold(body: child),
    ),
  );

  testWidgets('error cue: red error icon, heavy haptic, shakes', (t) async {
    await t.pumpWidget(
      host(const StatusCue(kind: CueKind.error, semanticLabel: 'bad input')),
    );
    final icon = t.widget<Icon>(find.byIcon(Icons.error));
    expect(icon.color, buildAppTheme().colorScheme.error);
    expect(haptics, ['HapticFeedbackType.heavyImpact']);
    await t.pump(const Duration(milliseconds: 100));
    final shifted = t.getTopLeft(find.byIcon(Icons.error)).dx;
    await t.pumpAndSettle();
    expect(t.getTopLeft(find.byIcon(Icons.error)).dx, isNot(shifted));
    expect(cueLabelled('bad input'), findsOneWidget);
  });

  testWidgets('reduced motion skips the shake but keeps the haptic', (t) async {
    await t.pumpWidget(
      host(
        const StatusCue(kind: CueKind.error, semanticLabel: 'bad input'),
        reduceMotion: true,
      ),
    );
    final start = t.getTopLeft(find.byIcon(Icons.error));
    await t.pump(const Duration(milliseconds: 100));
    expect(t.getTopLeft(find.byIcon(Icons.error)), start);
    expect(haptics, ['HapticFeedbackType.heavyImpact']);
  });

  testWidgets('ok cue taps lightly, info and warn stay silent', (t) async {
    await t.pumpWidget(
      host(const StatusCue(kind: CueKind.ok, semanticLabel: 'done')),
    );
    expect(haptics, ['HapticFeedbackType.lightImpact']);
    haptics.clear();
    for (final kind in [CueKind.info, CueKind.warn]) {
      await t.pumpWidget(host(StatusCue(kind: kind, semanticLabel: 'x')));
      expect(find.byIcon(kind.icon), findsOneWidget);
    }
    expect(haptics, isEmpty);
  });

  testWidgets('CueState.next bumps the sequence and rebuilds the cue', (
    t,
  ) async {
    final first = CueState.next(null, CueKind.info, 'a');
    final second = CueState.next(first, CueKind.info, 'a');
    expect(second.seq, first.seq + 1);
    await t.pumpWidget(host(second.widget));
    expect(cueLabelled('a'), findsOneWidget);
  });

  testWidgets('snackbar shows only a glyph and undo fires once', (t) async {
    var undone = 0;
    await t.pumpWidget(
      host(
        Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => showCueSnack(
              context,
              kind: CueKind.warn,
              semanticLabel: 'gone',
              onUndo: () => undone++,
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byIcon(Icons.add));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byType(Text), findsNothing);
    await t.tap(controlByLabel('Undo'));
    await t.pump();
    expect(undone, 1);
  });
}
