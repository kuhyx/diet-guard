/// The Dart half of the catering-credential sync gate.
///
/// `diet_guard/tests/test_kuchnia_credential_sync.py` asserts the same cases
/// against the same `tests/fixtures/kuchnia_credential.json`.
///
/// Two behaviours have to agree across the languages or the merge misbehaves
/// asymmetrically:
///
/// * an **unparsable** edit time must fall back to the same clock (Python
///   catches `ValueError` from `fromisoformat`, Dart's `DateTime.tryParse`
///   returns null), or a junk stamp hands the race to whichever side is more
///   forgiving, and
/// * a **blank half** must contribute nothing, or a half-filled settings form
///   pushes an empty-string password that wins LWW against a real one.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/services/sync_device_id.dart';
import 'package:diet_guard_app/services/sync_merge_kuchnia.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The repo root, found by walking up from the package directory.
Directory get _repoRoot {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate app/ from ${Directory.current.path}');
    }
    dir = parent;
  }
  return dir.parent;
}

void main() {
  late Map<String, dynamic> fixture;

  setUp(() async {
    // Pin the node id to the fixture's. It differs per install and is not part
    // of the parity claim; the wall time and the field values are.
    SharedPreferences.setMockInitialValues({
      kSyncDeviceIdKey: fixture['device_id'] as String,
    });
    resetSyncDeviceIdForTest();
    await initSyncDeviceId();
  });

  setUpAll(() {
    final file = File(
      '${_repoRoot.path}/tests/fixtures/kuchnia_credential.json',
    );
    expect(
      file.existsSync(),
      isTrue,
      reason: 'shared credential fixture missing at ${file.path}; regenerate '
          'with scripts/build_kuchnia_credential_fixture.py',
    );
    fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  });

  test('every shared case resolves the way Python resolves it', () {
    for (final raw in fixture['cases'] as List) {
      final testCase = (raw as Map).cast<String, dynamic>();
      final name = testCase['name'] as String;
      final log = credentialToLog(
        testCase['username'] as String,
        testCase['password'] as String,
        testCase['edited_at'] as String,
      );

      expect(log.isEmpty, equals(testCase['expected_empty']), reason: name);
      if (testCase['expected_empty'] as bool) continue;

      final record = log[kuchniaRecordId]!;
      expect(
        record.fields[kuchniaUsernameField]!.$1,
        equals(testCase['expected_username']),
        reason: name,
      );
      expect(
        record.fields[kuchniaPasswordField]!.$1,
        equals(testCase['expected_password']),
        reason: name,
      );
      expect(
        record.fields[kuchniaPasswordField]!.$2.wallTimeMs,
        equals(testCase['expected_wall_time_ms']),
        reason: '$name: the two languages disagree about this edit time, so a '
            'credential would resolve differently per device',
      );
    }
  });

  test('round trips through the wire format', () {
    final log = credentialToLog('me@example.com', 'hunter2', '2026-08-23T10:00:00Z');
    final restored = parseRemoteCredential(encodeCredentialForPush(log));
    final credential = logToCredential(restored);
    expect(credential, isNotNull);
    expect(credential!.username, equals('me@example.com'));
    expect(credential.password, equals('hunter2'));
  });

  test('an empty log reads back as not configured', () {
    expect(logToCredential({}), isNull);
  });

  test('a record missing a half reads back as not configured', () {
    final hlc = Hlc.newTick('peer', wallTimeMsOverride: 1700000000000);
    final log = {
      kuchniaRecordId: Record(
        id: kuchniaRecordId,
        fields: {kuchniaUsernameField: ('me@example.com', hlc)},
      ),
    };
    expect(logToCredential(log), isNull);
  });

  test('a blank half in a merged record reads back as not configured', () {
    final hlc = Hlc.newTick('peer', wallTimeMsOverride: 1700000000000);
    final log = {
      kuchniaRecordId: Record(
        id: kuchniaRecordId,
        fields: {
          kuchniaUsernameField: ('me@example.com', hlc),
          kuchniaPasswordField: ('', hlc),
        },
      ),
    };
    expect(logToCredential(log), isNull);
  });

  test('a field from a newer release is relayed, not dropped', () {
    // The same canary the Python suite runs. `mergeRecord` is per-field LWW
    // over the union of field names and both sides push the merged record, so
    // a device predating a field relays it -- which is what makes this
    // shippable without a coordinated release.
    final hlc = Hlc.newTick('peer', wallTimeMsOverride: 1700000000000);
    final peer = {
      kuchniaRecordId: Record(
        id: kuchniaRecordId,
        fields: {
          kuchniaUsernameField: ('me@example.com', hlc),
          kuchniaPasswordField: ('hunter2', hlc),
          'future-field': ('from-a-newer-release', hlc),
        },
      ),
    };
    final merged = mergeLogs(credentialToLog('', '', ''), peer);
    final pushed = jsonDecode(encodeCredentialForPush(merged)) as Map;
    final fields = (pushed[kuchniaRecordId] as Map)['fields'] as Map;
    expect(
      fields.containsKey('future-field'),
      isTrue,
      reason: 'a field from a newer release was dropped; this device would '
          'silently delete it from every peer on every tick',
    );
  });

  test('a non-object payload is rejected', () {
    expect(() => parseRemoteCredential('[1, 2]'), throwsFormatException);
  });
}
