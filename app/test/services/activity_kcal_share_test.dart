import 'package:diet_guard_app/services/activity_kcal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final today = DateTime(2026, 9, 28);
  const run = Session(
    day: '2026-09-22',
    kind: 'run',
    minutes: 60,
    km: 6,
    label: 'Run',
    source: 'runnerup',
  );

  group('extraShare', () {
    test('is zero with no past data', () {
      expect(extraShare(const [], today, const {'2026-09-28': 50}), 0);
    });

    test('uses the same window as dailyExercise, so it adds up', () {
      const steps = {'2026-09-26': 60.0, '2026-09-01': 999.0};
      // The 09-01 step day stretches the window to the full 14 days but is
      // itself outside it; only 09-26 counts.
      final share = extraShare(const [run], today, steps);
      expect(share, closeTo(60 / 14, 1e-9));
      final withSteps = dailyExercise(const [run], 80, today, steps);
      final without = dailyExercise(
        const [run],
        80,
        today,
        {'2026-09-01': 0.0},
      );
      expect(withSteps['MET']! - without['MET']!, closeTo(share, 1e-9));
    });
  });
}
