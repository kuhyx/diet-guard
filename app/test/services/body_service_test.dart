import 'dart:convert';

import 'package:diet_guard_app/models/body_document.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'body_test_support.dart';

final _t0 = DateTime.parse('2026-09-27T08:00:00');

void main() {
  late MemoryDocStore store;

  setUp(() async {
    store = MemoryDocStore();
    await BodyService.initForTesting(store);
  });
  tearDown(BodyService.resetForTesting);

  test('an empty store reads as an empty document', () {
    final body = BodyService.instance;
    expect(body.birth, isNull);
    expect(body.heightCm, isNull);
    expect(body.sex, isNull);
    expect(body.latestWeight, isNull);
    expect(body.sessions, isNull);
    expect(BodyService.isInitialized, isTrue);
  });

  test('a corrupt document reads as empty', () async {
    store.documents[BodyService.documentName] = '{not json';
    final body = await BodyService.initForTesting(store);
    expect(body.document.weights, isEmpty);
  });

  test('setProfile stamps only the fields given and persists', () async {
    final body = BodyService.instance;
    await body.setProfile(birth: '1995-03-01', heightCm: 180, now: _t0);
    await body.setProfile(sex: 'm', now: _t0.add(const Duration(hours: 1)));
    expect(body.birth, '1995-03-01');
    expect(body.heightCm, 180);
    expect(body.sex, 'm');
    final reloaded = await BodyService.initForTesting(store);
    expect(
      reloaded.document.profile[profileBirth]!.t,
      startsWith('2026-09-27T08'),
    );
    expect(
      reloaded.document.profile[profileSex]!.t,
      startsWith('2026-09-27T09'),
    );
  });

  test('weights: set, delete (tombstone), series and latest', () async {
    final body = BodyService.instance;
    await body.setWeight('2026-09-25', 81.5, now: _t0);
    await body.setWeight('2026-09-27', 80.9, now: _t0);
    await body.setWeight('2026-09-26', 81.2, now: _t0);
    expect(body.weightSeries.map((p) => p.$1), [
      '2026-09-25',
      '2026-09-26',
      '2026-09-27',
    ]);
    await body.deleteWeight('2026-09-27', now: _t0);
    expect(body.latestWeight, ('2026-09-26', 81.2));
    expect(body.document.weights['2026-09-27']!.kg, isNull);
    final saved = jsonDecode(store.documents[BodyService.documentName]!) as Map;
    expect((saved['weights'] as Map)['2026-09-27'], containsPair('kg', null));
  });

  test('applyCandidates only replaces missing or older entries', () async {
    final body = BodyService.instance;
    await body.setWeight('2026-09-26', 82, now: _t0);
    final changed = await body.applyCandidates({
      '2026-09-26': const WeightEntry(
        kg: 70,
        src: 'phone',
        t: '2026-09-26T00:00:00+00:00',
      ),
      '2026-09-25': const WeightEntry(
        kg: 81,
        src: 'phone',
        t: '2026-09-25T00:00:00+00:00',
      ),
    });
    expect(changed, isTrue);
    expect(body.document.weights['2026-09-26']!.kg, 82);
    expect(body.document.weights['2026-09-25']!.src, 'phone');
    final newer = await body.applyCandidates({
      '2026-09-26': const WeightEntry(
        kg: 79,
        src: 'phone',
        t: '2026-09-28T07:00:00+00:00',
      ),
    });
    expect(newer, isTrue);
    expect(body.document.weights['2026-09-26']!.kg, 79);
    expect(await body.applyCandidates(const {}), isFalse);
  });

  test('sessions parse the published activity, skipping malformed', () async {
    store.documents[BodyService.documentName] = jsonEncode({
      'activity': {
        't': '2026-09-27T10:00:00+02:00',
        'sessions': [
          {
            'day': '2026-09-26',
            'kind': 'run',
            'min': 30,
            'km': 5,
            'label': 'Run',
            'src': 'runnerup',
          },
          {'day': '2026-09-26', 'kind': 'strength', 'min': 60},
          {'day': 3},
          'junk',
          {'day': '2026-09-26', 'kind': 'run', 'min': 30, 'km': 'far'},
        ],
      },
    });
    final body = await BodyService.initForTesting(store);
    final sessions = body.sessions!;
    expect(sessions, hasLength(2));
    expect(sessions[0].km, 5);
    expect(sessions[1].label, 'strength');
    expect(sessions[1].source, '');
  });

  test('applyMerged replaces the document', () async {
    await BodyService.instance.applyMerged(
      const BodyDocument(
        weights: {'2026-09-20': WeightEntry(kg: 90, src: 'init', t: 'x')},
      ),
    );
    expect(BodyService.instance.latestWeight, ('2026-09-20', 90.0));
  });

  test('document parsing drops malformed parts', () {
    final doc = BodyDocument.fromJson({
      'profile': {
        'birth': {'v': '1990-01-01'},
        'sex': {'v': 'f', 't': 'x'},
      },
      'weights': {
        'yesterday': {'kg': 80, 't': 'x'},
        '2026-01-01': {'kg': 5, 't': 'x'},
        '2026-01-02': {'kg': 80},
        '2026-01-03': {'kg': 80, 't': 'x'},
      },
      'activity': {'sessions': 'nope', 't': 'x'},
    });
    expect(doc.profile.keys, ['sex']);
    expect(doc.weights.keys, ['2026-01-03']);
    expect(doc.weights['2026-01-03']!.src, 'manual');
    expect(doc.activity, isNull);
    expect(BodyDocument.fromJson('nope').weights, isEmpty);
  });

  test('body fat: set (rounded), delete, series and latest', () async {
    final body = BodyService.instance;
    await body.setBodyFat('2026-09-25', 20.04, now: _t0);
    await body.setBodyFat('2026-09-26', 19.55, now: _t0);
    expect(body.latestBodyFat, ('2026-09-26', 19.6));
    await body.deleteBodyFat('2026-09-26', now: _t0);
    expect(body.latestBodyFat, ('2026-09-25', 20.0));
    expect(body.document.bodyFat['2026-09-26']!.pct, isNull);
    final reloaded = await BodyService.initForTesting(store);
    expect(reloaded.bodyFatSeries, [('2026-09-25', 20.0)]);
  });

  test('profileComplete needs a real date, a height and m/f', () async {
    final body = BodyService.instance;
    expect(body.profileComplete, isFalse);
    await body.setProfile(birth: 'soon', heightCm: 180, sex: 'x');
    expect(body.profileComplete, isFalse);
    expect(body.sex, isNull);
    await body.setProfile(birth: '1990-01-01', sex: 'f');
    expect(body.profileComplete, isTrue);
  });

  test(
    'setProfileFields ignores an empty map and keeps other stamps',
    () async {
      final body = BodyService.instance;
      await body.setProfile(heightCm: 180, now: _t0);
      await body.setProfileFields(const {});
      await body.setProfileFields({
        'tbl_act': ['light'],
      }, now: _t0.add(const Duration(days: 1)));
      expect(body.profileValue('tbl_act'), ['light']);
      expect(body.document.profile[profileHeight]!.t, startsWith('2026-09-27'));
    },
  );
}
