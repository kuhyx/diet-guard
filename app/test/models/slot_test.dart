import 'package:diet_guard_app/models/slot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('daySlots', () {
    test('returns the four fixed hourly slots', () {
      expect(daySlots(), [8, 12, 16, 20]);
    });
  });

  group('withinEnforcementWindow', () {
    test('false before the day start hour', () {
      expect(withinEnforcementWindow(DateTime(2026, 6, 22, 7, 59)), isFalse);
    });

    test('true at the day start hour', () {
      expect(withinEnforcementWindow(DateTime(2026, 6, 22, 8, 0)), isTrue);
    });

    test('true just before the eating end hour', () {
      expect(withinEnforcementWindow(DateTime(2026, 6, 22, 21, 59)), isTrue);
    });

    test('false at the eating end hour (exclusive)', () {
      expect(withinEnforcementWindow(DateTime(2026, 6, 22, 22, 0)), isFalse);
    });
  });

  group('elapsedSlots', () {
    test('empty outside the enforcement window', () {
      expect(elapsedSlots(DateTime(2026, 6, 22, 23, 0)), isEmpty);
    });

    test('only the 8 slot right at day start', () {
      expect(elapsedSlots(DateTime(2026, 6, 22, 8, 0)), [8]);
    });

    test('8 and 12 mid-afternoon before 16', () {
      expect(elapsedSlots(DateTime(2026, 6, 22, 15, 59)), [8, 12]);
    });

    test('all four slots once 20:00 has passed', () {
      expect(elapsedSlots(DateTime(2026, 6, 22, 21, 0)), [8, 12, 16, 20]);
    });
  });

  group('missingSlots', () {
    test('excludes already-logged elapsed slots', () {
      expect(
        missingSlots(DateTime(2026, 6, 22, 17, 0), {8}),
        [12, 16],
      );
    });

    test('empty once every elapsed slot is logged', () {
      expect(
        missingSlots(DateTime(2026, 6, 22, 17, 0), {8, 12, 16}),
        isEmpty,
      );
    });
  });

  group('currentSlot', () {
    test('null outside the enforcement window', () {
      expect(currentSlot(DateTime(2026, 6, 22, 6, 0)), isNull);
    });

    test('returns the most recently elapsed slot', () {
      expect(currentSlot(DateTime(2026, 6, 22, 17, 41)), 16);
    });

    test('returns 8 right at day start', () {
      expect(currentSlot(DateTime(2026, 6, 22, 8, 0)), 8);
    });
  });

  group('slotLabel', () {
    test('pads single-digit hours', () {
      expect(slotLabel(8), '08:00');
    });

    test('formats double-digit hours', () {
      expect(slotLabel(20), '20:00');
    });
  });
}
