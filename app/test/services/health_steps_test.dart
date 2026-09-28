import 'package:diet_guard_app/models/body_document.dart';
import 'package:diet_guard_app/services/activity_kcal.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/services/health_steps.dart';
import 'package:diet_guard_app/services/health_steps_source_io.dart';
import 'package:diet_guard_app/services/health_steps_source_web.dart' as web;
import 'package:flutter_test/flutter_test.dart';

import 'body_test_support.dart';

/// A scripted Health Connect.
class FakeStepsSource implements StepsSource {
  FakeStepsSource({this.granted = true, this.intervals = const []});

  bool granted;
  bool grantOnRequest = true;
  List<StepInterval> intervals;
  Object? failWith;
  (DateTime, DateTime)? lastRead;

  @override
  bool get supported => true;

  @override
  Future<bool> hasPermission() async {
    final error = failWith;
    if (error != null) throw error;
    return granted;
  }

  @override
  Future<bool> requestPermission() async => granted = grantOnRequest;

  @override
  Future<List<StepInterval>> read(DateTime from, DateTime to) async {
    lastRead = (from, to);
    return intervals;
  }
}

DateTime _at(String iso) => DateTime.parse(iso);

StepInterval _steps(String from, String to, int n) =>
    StepInterval(_at(from), _at(to), n);

void main() {
  final original = stepsSource;
  tearDown(() {
    stepsSource = original;
    BodyService.resetForTesting();
  });

  test('intervals inside a workout window are dropped', () {
    const walk = Session(
      day: '2026-09-26',
      kind: 'walk',
      minutes: 60,
      km: 5,
      label: 'walk',
      source: 'screen-locker',
      start: '2026-09-26T18:00:00',
      end: '2026-09-26T19:00:00',
    );
    const noWindow = Session(
      day: '2026-09-26',
      kind: 'strength',
      minutes: 60,
      km: null,
      label: 'lift',
      source: 'screen-locker',
    );
    final counts = stepsOutsideWorkouts(
      [
        _steps('2026-09-26T08:00:00', '2026-09-26T09:00:00', 3000),
        _steps('2026-09-26T18:30:00', '2026-09-26T18:45:00', 2000),
        _steps('2026-09-26T17:50:00', '2026-09-26T18:05:00', 500),
        _steps('2026-09-26T19:00:00', '2026-09-26T19:10:00', 400),
        _steps('2026-09-27T10:00:00', '2026-09-27T11:00:00', 7000),
      ],
      [walk, noWindow],
    );
    expect(counts, {'2026-09-26': 3400, '2026-09-27': 7000});
  });

  test('session start/end parse tolerantly from the wire', () {
    final parsed = Session.fromWire({
      'day': '2026-09-26',
      'kind': 'walk',
      'min': 60,
      'start': '2026-09-26T18:00:00+02:00',
      'end': 'soon',
    })!;
    expect(parsed.start, '2026-09-26T18:00:00+02:00');
    expect(parsed.end, isNull);
  });

  test('applySteps re-stamps only changed days', () async {
    final body = await BodyService.initForTesting(MemoryDocStore());
    final t0 = _at('2026-09-27T08:00:00');
    expect(await applySteps(body, {'2026-09-26': 100}, now: t0), isTrue);
    final stamp = body.document.steps['2026-09-26']!.t;
    final later = t0.add(const Duration(hours: 1));
    expect(await applySteps(body, {'2026-09-26': 100}, now: later), isFalse);
    expect(body.document.steps['2026-09-26']!.t, stamp);
    await applySteps(body, {'2026-09-26': 150}, now: later);
    expect(body.document.steps['2026-09-26']!.n, 150);
  });

  test('refreshSteps reads 28 days when permitted, never prompts', () async {
    await BodyService.initForTesting(MemoryDocStore());
    final fake = FakeStepsSource(
      granted: false,
      intervals: [_steps('2026-09-26T08:00:00', '2026-09-26T09:00:00', 42)],
    );
    stepsSource = fake;
    final now = _at('2026-09-28T12:00:00');
    expect(await refreshSteps(now: now), isFalse);
    expect(fake.lastRead, isNull);
    fake.granted = true;
    expect(await refreshSteps(now: now), isTrue);
    expect(fake.lastRead!.$1, DateTime(2026, 8, 31));
    expect(BodyService.instance.document.steps['2026-09-26']!.n, 42);
    fake.failWith = StateError('Health Connect gone');
    expect(await refreshSteps(now: now), isFalse);
  });

  test('refreshSteps no-ops without the body service', () async {
    stepsSource = FakeStepsSource();
    expect(await refreshSteps(), isFalse);
  });

  test('platform sources: web and non-Android report unsupported', () async {
    const source = web.NoStepsSource();
    expect(source.supported, isFalse);
    expect(await source.hasPermission(), isFalse);
    expect(await source.requestPermission(), isFalse);
    expect(await source.read(DateTime(2026), DateTime(2026, 2)), isEmpty);
    expect(web.createStepsSource().supported, isFalse);
    expect(createStepsSource().supported, isFalse);
    expect(HealthConnectStepsSource().supported, isFalse);
    stepsSource = HealthConnectStepsSource();
    await BodyService.initForTesting(MemoryDocStore());
    expect(await refreshSteps(), isFalse);
    expect(BodyService.instance.document.steps, isEmpty);
    expect(const StepsEntry(n: 1, t: 'x').toJson(), {'n': 1, 't': 'x'});
  });
}
