import 'package:diet_guard_app/models/day_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('YtdTally', () {
    test('equal tallies compare equal and share hashCode', () {
      const a = YtdTally(loggedDays: 5, elapsedDays: 10, adherentDays: 3);
      const b = YtdTally(loggedDays: 5, elapsedDays: 10, adherentDays: 3);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('differing tallies compare unequal', () {
      const a = YtdTally(loggedDays: 5, elapsedDays: 10, adherentDays: 3);
      const b = YtdTally(loggedDays: 4, elapsedDays: 10, adherentDays: 3);
      expect(a, isNot(equals(b)));
    });

    test('is not equal to an unrelated object', () {
      const a = YtdTally(loggedDays: 5, elapsedDays: 10, adherentDays: 3);
      const Object other = 'not a tally';
      expect(a == other, isFalse);
    });

    test('toString is human-readable', () {
      const a = YtdTally(loggedDays: 5, elapsedDays: 10, adherentDays: 3);
      expect(a.toString(), 'YtdTally(logged: 5/10, adherent: 3)');
    });
  });

  test('DayStatus has exactly the four expected values', () {
    expect(DayStatus.values, [
      DayStatus.notLogged,
      DayStatus.red,
      DayStatus.yellow,
      DayStatus.green,
    ]);
  });
}
