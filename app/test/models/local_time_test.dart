import 'package:diet_guard_app/models/local_time.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isoLocalSeconds', () {
    test('includes a positive UTC offset with second precision', () {
      final result = isoLocalSeconds(
        DateTime(2026, 6, 22, 17, 41, 17),
      );
      expect(result, startsWith('2026-06-22T17:41:17'));
      expect(result, matches(RegExp(r'[+-]\d{2}:\d{2}$')));
    });

    test('pads single-digit month, day, and time components', () {
      final result = isoLocalSeconds(DateTime(2026, 1, 2, 3, 4, 5));
      expect(result, startsWith('2026-01-02T03:04:05'));
    });
  });

  group('localDateKey', () {
    test('returns just the date portion', () {
      expect(localDateKey(DateTime(2026, 6, 22, 23, 59)), '2026-06-22');
    });
  });
}
