// The date picker's selection rules, as plain unit tests.

import 'package:diet_guard_app/widgets/pickers/date_selection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _first = DateTime(2026, 1, 15);
final _last = DateTime(2026, 6, 10);

DateSelection _single(DateTime initial) =>
    DateSelection.single(first: _first, last: _last, initial: initial);

DateSelection _range([DateTimeRange? initial]) =>
    DateSelection.range(first: _first, last: _last, initial: initial);

void main() {
  group('bounds', () {
    test('an initial day outside the bounds is clamped in', () {
      expect(_single(DateTime(2025, 12)).start, _first);
      expect(_single(DateTime(2027)).start, _last);
      final s = _single(DateTime(2027));
      expect((s.year, s.month), (2026, 6));
    });

    test('a time of day is dropped from every date', () {
      final s = DateSelection.single(
        first: DateTime(2026, 1, 1, 13),
        last: DateTime(2026, 2, 1, 23, 59),
        initial: DateTime(2026, 1, 5, 18),
      );
      expect(s.first, DateTime(2026));
      expect(s.last, DateTime(2026, 2));
      expect(s.start, DateTime(2026, 1, 5));
    });

    test('out-of-range days are inert', () {
      final s = _single(DateTime(2026, 3, 3))..tap(DateTime(2026, 1, 14));
      expect(s.start, DateTime(2026, 3, 3));
    });

    test('a month is allowed when any of its days is in range', () {
      final s = _single(DateTime(2026, 3, 3));
      expect(s.monthAllowed(2026, 1), isTrue);
      expect(s.monthAllowed(2026, 6), isTrue);
      expect(s.monthAllowed(2026, 7), isFalse);
      expect(s.monthAllowed(2025, 12), isFalse);
    });
  });

  group('single', () {
    test('a tap selects without confirming; the check is always on', () {
      final s = _single(DateTime(2026, 3, 3))..tap(DateTime(2026, 3, 9));
      expect(s.start, DateTime(2026, 3, 9));
      expect(s.canConfirm, isTrue);
    });

    test('a 31st moved to a 30-day month lands on the 30th', () {
      final s = _single(DateTime(2026, 3, 31))..showMonth(4);
      expect(s.start, DateTime(2026, 4, 30));
    });

    test('a month change clamps the day into the bounds', () {
      final s = _single(DateTime(2026, 3, 20))..showMonth(6);
      expect(s.start, _last);
      s.showMonth(1);
      expect(s.start, _first, reason: 'day 10 of January is before the 15th');
    });

    test('a year change pulls the month into the edge year', () {
      final s = DateSelection.single(
        first: DateTime(2025, 9),
        last: DateTime(2026, 3, 31),
        initial: DateTime(2025, 11, 4),
      )..showYear(2026);
      expect((s.year, s.month), (2026, 3));
      expect(s.start, DateTime(2026, 3, 4));
      s.showYear(2025);
      expect((s.year, s.month), (2025, 9));
    });

    test('arrows move the selection, across months, stopping at bounds', () {
      final s = _single(DateTime(2026, 1, 31))..moveCursor(1);
      expect(s.start, DateTime(2026, 2));
      expect(s.month, 2);
      s.moveCursor(-7);
      expect(s.start, DateTime(2026, 1, 25));
      s
        ..moveCursor(-7)
        ..moveCursor(-7);
      expect(s.start, DateTime(2026, 1, 18), reason: 'the 11th is out');
    });
  });

  group('range', () {
    test('one tap leaves the check off; two taps turn it on', () {
      final s = _range()..tap(DateTime(2026, 3, 2));
      expect(s.canConfirm, isFalse);
      s.tap(DateTime(2026, 3, 9));
      expect(s.canConfirm, isTrue);
      expect(s.dateRange!.start, DateTime(2026, 3, 2));
      expect(s.dateRange!.end, DateTime(2026, 3, 9));
    });

    test('a later day tapped first still gives an ordered range', () {
      final s = _range()
        ..tap(DateTime(2026, 3, 9))
        ..tap(DateTime(2026, 3, 2));
      expect(s.dateRange!.start, DateTime(2026, 3, 2));
      expect(s.dateRange!.end, DateTime(2026, 3, 9));
    });

    test('the same day twice is a one-day range', () {
      final s = _range()
        ..tap(DateTime(2026, 3, 4))
        ..tap(DateTime(2026, 3, 4));
      expect(s.canConfirm, isTrue);
      expect(s.dateRange!.duration, Duration.zero);
    });

    test('a third tap restarts from that day', () {
      final s = _range()
        ..tap(DateTime(2026, 3, 2))
        ..tap(DateTime(2026, 3, 9))
        ..tap(DateTime(2026, 4));
      expect(s.start, DateTime(2026, 4));
      expect(s.end, isNull);
      expect(s.canConfirm, isFalse);
    });

    test('a preset range counts as both taps', () {
      final s = _range(
        DateTimeRange(start: DateTime(2026, 2, 2), end: DateTime(2026, 2, 8)),
      );
      expect(s.canConfirm, isTrue);
      expect((s.year, s.month), (2026, 2));
    });

    test('navigating never moves the chosen ends', () {
      final s = _range()
        ..tap(DateTime(2026, 3, 31))
        ..tap(DateTime(2026, 4, 2))
        ..showMonth(2)
        ..showYear(2026)
        ..moveCursor(3);
      expect(s.start, DateTime(2026, 3, 31));
      expect(s.end, DateTime(2026, 4, 2));
    });

    test('with no preset the cursor starts on today, clamped', () {
      final s = _range();
      expect(s.start, isNull);
      expect(s.allows(s.cursor), isTrue);
    });
  });
}
