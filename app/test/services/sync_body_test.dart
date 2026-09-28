import 'dart:convert';

import 'package:diet_guard_app/models/body_document.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/services/sync_body.dart';
import 'package:diet_guard_app/services/sync_device_id.dart';
import 'package:diet_guard_app/services/sync_merge_body.dart';
import 'package:flutter_test/flutter_test.dart';

import 'body_test_support.dart';

const _dir = 'diet-guard-sync/devices';

void main() {
  tearDown(BodyService.resetForTesting);

  test('no-ops when the body service is not initialised', () async {
    final remote = MemoryRemote();
    await syncBody(remote, devicesDir: _dir);
    expect(remote.files, isEmpty);
  });

  test('merges a peer, ingests the weigh-in, pushes the result', () async {
    await BodyService.initForTesting(MemoryDocStore());
    await BodyService.instance.setProfile(
      heightCm: 180,
      now: DateTime.parse('2026-09-01T10:00:00'),
    );
    final peer = BodyDocument(
      profile: const {
        profileBirth: Stamped('1995-03-01', '2026-09-02T10:00:00+02:00'),
      },
      activity: const ActivityData(
        sessions: [
          {'day': '2026-09-26', 'kind': 'strength', 'min': 80},
        ],
        t: '2026-09-27T10:00:00+02:00',
      ),
    );
    final remote = MemoryRemote({
      '$_dir/pc-uuid/body.json': encodeBodyForPush(bodyToLog(peer)),
      'wake-alarm-sync/devices/phone/alarm.json': jsonEncode({
        'alarm': {
          'fields': {
            'morning_sessions': [
              [
                {'date': '2026-09-27', 'weight_kg': 80.5},
              ],
              '2026-09-27T05:00:00.000Z-0000-phone',
            ],
          },
        },
      }),
    });

    await syncBody(remote, devicesDir: _dir);

    final body = BodyService.instance;
    expect(body.birth, '1995-03-01');
    expect(body.heightCm, 180);
    expect(body.latestWeight, ('2026-09-27', 80.5));
    expect(body.sessions, hasLength(1));
    final pushed = remote.files['$_dir/$currentSyncDeviceId/body.json'];
    expect(pushed, isNotNull);
    final pushedDoc = logToBody(parseRemoteBody(pushed!));
    expect(pushedDoc.weights.keys, ['2026-09-27']);
    expect(pushedDoc.profile.keys.toSet(), {profileBirth, profileHeight});
  });
}
