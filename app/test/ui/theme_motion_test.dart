import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('durations follow the shared motion scale', () {
    expect(AppDuration.instant, Duration.zero);
    expect(AppDuration.fast, const Duration(milliseconds: 120));
    expect(AppDuration.base, const Duration(milliseconds: 200));
    expect(AppDuration.slow, const Duration(milliseconds: 320));
  });

  test('curves carry the shared control points', () {
    expect(AppCurve.standard, const Cubic(0.2, 0, 0, 1));
    expect(AppCurve.decelerate, const Cubic(0, 0, 0, 1));
    expect(AppCurve.accelerate, const Cubic(0.3, 0, 1, 1));
  });

  Future<Duration> resolved(
    WidgetTester tester, {
    required bool reduced,
  }) async {
    late Duration out;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Builder(
          builder: (context) {
            out = AppDuration.resolve(context, AppDuration.slow);
            return const SizedBox();
          },
        ),
      ),
    );
    return out;
  }

  testWidgets('resolve collapses to zero under disableAnimations', (
    tester,
  ) async {
    expect(await resolved(tester, reduced: true), Duration.zero);
  });

  testWidgets('resolve returns the token otherwise', (tester) async {
    expect(await resolved(tester, reduced: false), AppDuration.slow);
  });
}
