/// Pointer-free operability tests for controls that had no keyboard route.
///
/// The desktop build is this Dart running as Flutter **web** in a Chrome
/// `--app` window, so "mobile-only" gestures are not a fallback there — they
/// are the whole interaction. Each test below stands in for something that was
/// literally impossible without a pointer.
///
/// These are also the repo's first keyboard-reachability assertions: before
/// this file, `test/` had ~109 `tester.tap` calls and zero checks that anything
/// was focusable at all.
library;

import 'dart:io';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/history_screen.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/day_status_calendar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// Landscape and *short* — the supported floor. Phone-portrait sizes, which is
/// all the existing suite pinned, exercise neither constraint.
const _desktopSize = Size(1366, 768);

void main() {
  group('calendar day cells', () {
    testWidgets('are focusable, so date navigation has a keyboard route', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DayStatusCalendar(
              statusByDate: const {},
              month: DateTime(2026, 7),
              today: DateTime(2026, 7, 30),
              onPrevMonth: _noop,
              onNextMonth: _noop,
              onDaySelected: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // A bare GestureDetector — what this replaced — builds no InkWell and no
      // focus node, so no day was reachable by Tab and the whole
      // date-filtered-history route was pointer-only.
      expect(
        find.byType(InkWell),
        findsWidgets,
        reason: 'day cells must be focusable, not bare GestureDetectors',
      );
    });

    testWidgets('expose a button semantic for screen readers', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DayStatusCalendar(
              statusByDate: const {},
              month: DateTime(2026, 7),
              today: DateTime(2026, 7, 30),
              onPrevMonth: _noop,
              onNextMonth: _noop,
              onDaySelected: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final node = tester.getSemantics(find.byType(InkWell).first);
      expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
      // Disposed inline, not via addTearDown: Flutter verifies outstanding
      // handles at the end of the test body, before tearDowns run.
      handle.dispose();
    });

    testWidgets('gain a tab stop per day only when selection is enabled', (
      tester,
    ) async {
      // Counts InkWells rather than matching a semantics label: the day cells
      // merge their own label with the day-number Text inside them, so a label
      // finder is brittle. The month-navigation chevrons are IconButtons and
      // contribute a constant number of InkWells in both cases, so the
      // *difference* is exactly the per-day tab stops -- which is the property
      // under test.
      Future<int> inkWells({required bool selectable}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DayStatusCalendar(
                statusByDate: const {},
                month: DateTime(2026, 7),
                today: DateTime(2026, 7, 30),
                onPrevMonth: _noop,
                onNextMonth: _noop,
                onDaySelected: selectable ? (_) {} : null,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return tester.widgetList(find.byType(InkWell)).length;
      }

      final readOnlyCount = await inkWells(selectable: false);
      final selectableCount = await inkWells(selectable: true);

      // July 2026 has 31 days. Before the fix this difference was zero: the
      // cells were bare GestureDetectors, so no day was ever a tab stop.
      expect(selectableCount - readOnlyCount, 31);
    });
  });

  group('width caps', () {
    test('prose cap matches the design-system line-length rule', () {
      // tokens.md rule 21: 40rem / ~65-70 characters. Without this the desktop
      // window rendered prose at roughly 180 characters per line.
      expect(AppWidth.prose, 640);
    });

    test('a single-purpose field is capped well below the prose width', () {
      expect(AppWidth.field, lessThan(AppWidth.prose));
    });

    test('the short-viewport breakpoint trips before the 768px floor', () {
      expect(AppWidth.shortViewport, lessThan(768));
    });
  });

  group('history entry delete', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('diet_guard_kbd_');
      LogStorageService.resetForTesting(store: FileDocumentStore(tempDir));
      BudgetHistoryService.resetForTesting(store: FileDocumentStore(tempDir));
    });

    tearDown(() async {
      LogStorageService.resetForTesting();
      BudgetHistoryService.resetForTesting();
      await tempDir.delete(recursive: true);
    });

    testWidgets('has a focusable control, not long-press only', (tester) async {
      tester.view.physicalSize = _desktopSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pumpHistoryScreen(tester, {
        '2026-07-30': [
          const FoodEntry(
            id: 'has-id',
            time: '2026-07-30T08:00:00+02:00',
            desc: 'oatmeal with raisins',
            grams: 100,
            kcal: 430,
            proteinG: 12,
            carbsG: 60,
            fatG: 9,
            source: 'food bank',
          ),
        ],
      });

      // Delete used to be bound only to onLongPress, which has no keyboard
      // equivalent whatsoever.
      expect(
        find.byTooltip('Delete entry'),
        findsOneWidget,
        reason: 'delete needs a tab-reachable control, not long-press only',
      );
    });

    testWidgets('offers no delete control for an entry without an id', (
      tester,
    ) async {
      tester.view.physicalSize = _desktopSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pumpHistoryScreen(tester, {
        '2026-07-30': [
          const FoodEntry(
            time: '2026-07-30T09:00:00+02:00',
            desc: 'legacy entry',
            grams: 100,
            kcal: 100,
            proteinG: 1,
            carbsG: 2,
            fatG: 3,
            source: 'legacy',
          ),
        ],
      });

      // Delete stays id-only to avoid ambiguous time+desc matches, so the
      // control must be absent rather than present-and-failing.
      expect(find.byTooltip('Delete entry'), findsNothing);
    });
  });
}

/// A do-nothing month-navigation callback.
void _noop() {}

/// Seed [log] to disk, then pump [HistoryScreen] until its load has painted.
///
/// Both halves must happen inside `runAsync`, and that is the whole point of
/// this helper. `LogStorageService` here is backed by a `FileDocumentStore`,
/// so `writeLog` awaits real `dart:io`; awaited from the test body it waits
/// on a `Future` the fake-async zone never completes, and the test hangs
/// rather than failing -- reported only as "did not complete" once the suite
/// times out. `HistoryScreen` then loads through a fire-and-forget `Future`
/// in `initState`, which needs the same real clock to resolve.
///
/// The pumping is a bounded manual loop rather than `pumpAndSettle()`, which
/// inside `runAsync` waits on a frame scheduler this screen never reports as
/// idle -- another hang, with the same unhelpful symptom.
Future<void> _pumpHistoryScreen(WidgetTester tester, DayLog log) async {
  await tester.runAsync(() async {
    await LogStorageService.instance.writeLog(log);
    await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
    }
  });
}
