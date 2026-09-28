import 'dart:convert';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/body_document.dart';
import 'package:diet_guard_app/services/sync_merge_body.dart';
import 'package:flutter_test/flutter_test.dart';

const _sessions = [
  {'day': '2026-09-26', 'kind': 'run', 'min': 30, 'km': 5},
];

BodyDocument _doc({
  String heightT = '2026-09-01T10:00:00+02:00',
  String birthT = '2026-09-01T10:00:00+02:00',
  double height = 180,
  String birth = '1995-03-01',
  Map<String, WeightEntry> weights = const {},
  ActivityData? activity,
}) => BodyDocument(
  profile: {
    profileHeight: Stamped(height, heightT),
    profileBirth: Stamped(birth, birthT),
    profileSex: const Stamped('m', '2026-09-01T10:00:00+02:00'),
  },
  weights: weights,
  activity: activity,
);

void main() {
  test('round-trips a document through the wire format', () {
    final doc = _doc(
      weights: const {
        '2026-09-26': WeightEntry(
          kg: 81.2,
          src: 'phone',
          t: '2026-09-26T07:12:03+02:00',
        ),
        '2026-09-27': WeightEntry(
          kg: null,
          src: 'manual',
          t: '2026-09-27T09:00:00+02:00',
        ),
      },
      activity: const ActivityData(
        sessions: _sessions,
        t: '2026-09-27T10:00:00+02:00',
      ),
    );
    final wire = encodeBodyForPush(bodyToLog(doc));
    final back = logToBody(parseRemoteBody(wire));
    expect(back.profile[profileHeight]!.value, 180.0);
    expect(back.profile[profileBirth]!.value, '1995-03-01');
    expect(back.profile[profileSex]!.value, 'm');
    expect(
      stampMillis(back.profile[profileHeight]!.t),
      stampMillis('2026-09-01T10:00:00+02:00'),
    );
    expect(back.weights['2026-09-26']!.kg, 81.2);
    expect(back.weights['2026-09-26']!.src, 'phone');
    expect(back.weights['2026-09-27']!.kg, isNull);
    expect(back.activity!.sessions, _sessions);
    // Re-deriving from the round-tripped stamps gives the same clocks, so
    // an unchanged document re-pushes byte-identical text. Compared as
    // text: Record equality is shallow over map/list values.
    expect(encodeBodyForPush(bodyToLog(back)), wire);
  });

  test('profile fields merge independently, last writer wins each', () {
    final phone = _doc(height: 181, heightT: '2026-09-20T10:00:00+02:00');
    final pc = _doc(birth: '1994-03-01', birthT: '2026-09-21T10:00:00+02:00');
    final merged = logToBody(mergeLogs(bodyToLog(phone), bodyToLog(pc)));
    expect(merged.profile[profileHeight]!.value, 181.0);
    expect(merged.profile[profileBirth]!.value, '1994-03-01');
  });

  test('an empty document is an empty log', () {
    expect(bodyToLog(const BodyDocument()), isEmpty);
    final back = logToBody(const {});
    expect(back.profile, isEmpty);
    expect(back.activity, isNull);
  });

  test('malformed wire parts are skipped', () {
    final hlc = Hlc.newTick('n', wallTimeMsOverride: 1000);
    final log = <String, Record>{
      'profile': Record(
        id: 'profile',
        fields: {'height_cm': ('tall', hlc), 'birth': (3, hlc)},
      ),
      'w:bad': Record(
        id: 'w:bad',
        fields: {
          'kg': ({'kg': 80}, hlc),
        },
      ),
      'w:2026-01-01': Record(id: 'w:2026-01-01', fields: const {}),
      'w:2026-01-02': Record(
        id: 'w:2026-01-02',
        fields: {
          'kg': ({'kg': 1000}, hlc),
        },
      ),
      'w:2026-01-03': Record(
        id: 'w:2026-01-03',
        fields: {
          'kg': ({'kg': 80}, hlc),
        },
        deleted: true,
      ),
      'bf:bad': Record(
        id: 'bf:bad',
        fields: {
          'pct': ({'pct': 20}, hlc),
        },
      ),
      'bf:2026-01-01': Record(id: 'bf:2026-01-01', fields: const {}),
      'bf:2026-01-02': Record(
        id: 'bf:2026-01-02',
        fields: {
          'pct': ({'pct': 90}, hlc),
        },
      ),
      'bf:2026-01-03': Record(
        id: 'bf:2026-01-03',
        fields: {
          'pct': ({'pct': 20}, hlc),
        },
        deleted: true,
      ),
      'st:bad': Record(
        id: 'st:bad',
        fields: {
          'n': ({'n': 5}, hlc),
        },
      ),
      'st:2026-01-01': Record(id: 'st:2026-01-01', fields: const {}),
      'st:2026-01-02': Record(
        id: 'st:2026-01-02',
        fields: {
          'n': ({'n': -1}, hlc),
        },
      ),
      'st:2026-01-03': Record(
        id: 'st:2026-01-03',
        fields: {
          'n': ({'n': 5}, hlc),
        },
        deleted: true,
      ),
      'activity': Record(id: 'activity', fields: {'sessions': ('x', hlc)}),
    };
    final doc = logToBody(log);
    // Profile fields are relayed as merged; the service validates on read.
    expect(doc.profile.keys.toSet(), {'height_cm', 'birth'});
    expect(doc.weights, isEmpty);
    expect(doc.bodyFat, isEmpty);
    expect(doc.steps, isEmpty);
    expect(doc.activity, isNull);
  });

  test('body fat, steps and the goal round-trip; goal keeps its own stamp', () {
    const doc = BodyDocument(
      profile: {
        profileHeight: Stamped(180, '2026-09-01T10:00:00+02:00'),
        'goal': Stamped({'dir': 'gain'}, '2026-09-05T10:00:00+02:00'),
      },
      steps: {
        '2026-09-26': StepsEntry(n: 9123, t: '2026-09-26T21:00:00+02:00'),
      },
      bodyFat: {
        '2026-09-26': BodyFatEntry(pct: 18.5, t: '2026-09-26T08:00:00+02:00'),
        '2026-09-27': BodyFatEntry(pct: null, t: '2026-09-27T08:00:00+02:00'),
      },
    );
    final wire = encodeBodyForPush(bodyToLog(doc));
    final raw = jsonDecode(wire) as Map<String, dynamic>;
    expect(
      (raw['bf:2026-09-26'] as Map)['fields'],
      containsPair('pct', [
        {'pct': 18.5},
        isA<String>(),
      ]),
    );
    final back = logToBody(parseRemoteBody(wire));
    expect(back.bodyFat['2026-09-26']!.pct, 18.5);
    expect(back.bodyFat['2026-09-27']!.pct, isNull);
    expect(back.profile['goal']!.value, {'dir': 'gain'});
    expect(back.steps['2026-09-26']!.n, 9123);
    expect(
      (raw['st:2026-09-26'] as Map)['fields'],
      containsPair('n', [
        {'n': 9123},
        isA<String>(),
      ]),
    );
    expect(
      stampMillis(back.profile['goal']!.t),
      isNot(stampMillis(back.profile[profileHeight]!.t)),
    );
    expect(encodeBodyForPush(bodyToLog(back)), wire);
  });

  test('stamps keep milliseconds only when the clock has them', () {
    expect(
      stampFromHlc(Hlc.newTick('n', wallTimeMsOverride: 1500)),
      '1970-01-01T00:00:01.500Z',
    );
    final whole = stampFromHlc(Hlc.newTick('n', wallTimeMsOverride: 2000));
    expect(stampMillis(whole), 2000);
    expect(whole, isNot(contains('.')));
  });

  test('a non-object payload is rejected', () {
    expect(() => parseRemoteBody('[]'), throwsFormatException);
  });
}
