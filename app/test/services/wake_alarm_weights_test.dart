import 'dart:convert';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/body_document.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/services/wake_alarm_weights.dart';
import 'package:flutter_test/flutter_test.dart';

import 'body_test_support.dart';

String _hlc(String iso) => Hlc.newTick(
  'phone-uuid',
  wallTimeMsOverride: DateTime.parse(iso).millisecondsSinceEpoch,
).toStr();

String _alarm({Object? latest, String? latestHlc, Object? sessions}) =>
    jsonEncode({
      'alarm': {
        'id': 'alarm',
        'deleted': false,
        'fields': {
          'latest_weight_kg': ?(latest == null
              ? null
              : [latest, latestHlc ?? _hlc('2026-09-27T05:30:00Z')]),
          'morning_sessions': ?(sessions == null
              ? null
              : [sessions, _hlc('2026-09-27T05:31:00Z')]),
        },
      },
    });

void main() {
  test('latest weigh-in is stamped by its own clock', () {
    final out = wakeAlarmCandidates([
      ('phone', _alarm(latest: {'date': '2026-09-27', 'kg': 80.4})),
    ]);
    expect(out['2026-09-27']!.kg, 80.4);
    expect(out['2026-09-27']!.src, 'phone');
    expect(
      stampMillis(out['2026-09-27']!.t),
      DateTime.parse('2026-09-27T05:30:00Z').millisecondsSinceEpoch,
    );
  });

  test('sessions fill gaps at midnight and lose to the latest field', () {
    final out = wakeAlarmCandidates([
      (
        'phone',
        _alarm(
          latest: {'date': '2026-09-27', 'kg': 80.4},
          sessions: [
            {'date': '2026-09-27', 'weight_kg': 99},
            {'date': '2026-09-26', 'weight_kg': 81},
            {'date': '2026-09-25', 'weight_kg': null},
            {'date': '2026-09-24', 'weight_kg': 5},
            {'date': 'monday', 'weight_kg': 81},
            'junk',
          ],
        ),
      ),
    ]);
    expect(out.keys.toSet(), {'2026-09-27', '2026-09-26'});
    expect(out['2026-09-27']!.kg, 80.4);
    expect(out['2026-09-26']!.t, '2026-09-26T00:00:00+00:00');
  });

  test('the newest stamp per day wins across devices', () {
    final out = wakeAlarmCandidates([
      (
        'a',
        _alarm(
          latest: {'date': '2026-09-27', 'kg': 80},
          latestHlc: _hlc('2026-09-27T05:00:00Z'),
        ),
      ),
      (
        'b',
        _alarm(
          latest: {'date': '2026-09-27', 'kg': 79},
          latestHlc: _hlc('2026-09-27T06:00:00Z'),
        ),
      ),
      (
        'c',
        _alarm(
          latest: {'date': '2026-09-27', 'kg': 78},
          latestHlc: _hlc('2026-09-27T04:00:00Z'),
        ),
      ),
    ]);
    expect(out['2026-09-27']!.kg, 79);
  });

  test('unusable devices are skipped', () {
    final out = wakeAlarmCandidates([
      ('bad-json', '{nope'),
      ('not-map', '[]'),
      ('no-fields', jsonEncode({'alarm': {}})),
      (
        'bad-hlc',
        _alarm(latest: {'date': '2026-09-27', 'kg': 80}, latestHlc: 'x'),
      ),
      ('bad-sessions', _alarm(sessions: 'x')),
      ('bool-kg', _alarm(latest: {'date': '2026-09-27', 'kg': true})),
    ]);
    expect(out, isEmpty);
  });

  group('ingestWakeAlarmWeights', () {
    tearDown(BodyService.resetForTesting);

    test('no-ops when the body service is not initialised', () async {
      expect(await ingestWakeAlarmWeights(MemoryRemote()), isFalse);
    });

    test('applies every device\'s weigh-ins', () async {
      await BodyService.initForTesting(MemoryDocStore());
      final remote = MemoryRemote({
        '$wakeAlarmDevicesDir/phone-uuid/alarm.json': _alarm(
          latest: {'date': '2026-09-27', 'kg': 80.4},
        ),
        '$wakeAlarmDevicesDir/other/state.json': '{}',
      });
      expect(await ingestWakeAlarmWeights(remote), isTrue);
      expect(BodyService.instance.latestWeight, ('2026-09-27', 80.4));
    });

    test('never throws out of the sync tick', () async {
      await BodyService.initForTesting(MemoryDocStore());
      final remote = MemoryRemote()..failWith = RemoteSyncError('offline');
      expect(await ingestWakeAlarmWeights(remote), isFalse);
    });
  });
}
