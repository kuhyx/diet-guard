import 'package:diet_guard_app/services/github_client_factory.dart';
import 'package:diet_guard_app/services/sync_device_id.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetSyncDeviceIdForTest();
  });

  group('initSyncDeviceId', () {
    test('mints and persists a uuid on first run', () async {
      final minted = await initSyncDeviceId();

      expect(Uuid.isValidUUID(fromString: minted), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kSyncDeviceIdKey), minted);
    });

    test('returns the same id on every later run', () async {
      final first = await initSyncDeviceId();
      resetSyncDeviceIdForTest();

      expect(await initSyncDeviceId(), first);
    });

    test('adopts an id already stored under the shared key', () async {
      SharedPreferences.setMockInitialValues({
        kSyncDeviceIdKey: 'pre-existing-id',
      });

      expect(await initSyncDeviceId(), 'pre-existing-id');
    });

    test('treats a blank stored id as absent', () async {
      SharedPreferences.setMockInitialValues({kSyncDeviceIdKey: ''});

      expect(await initSyncDeviceId(), isNotEmpty);
    });

    test('is idempotent', () async {
      final first = await initSyncDeviceId();

      expect(await initSyncDeviceId(), first);
    });
  });

  group('currentSyncDeviceId', () {
    test('falls back to the role constant before init runs', () {
      // A caller that stamps an Hlc before startup finishes must still get a
      // valid id -- the pre-migration one -- rather than crash.
      expect(currentSyncDeviceId, syncDeviceId);
    });

    test('returns the persisted uuid once init has run', () async {
      final minted = await initSyncDeviceId();

      expect(currentSyncDeviceId, minted);
      expect(currentSyncDeviceId, isNot(syncDeviceId));
    });
  });

  group('legacySyncDeviceId', () {
    test('is the role constant this build shipped with', () {
      // Passed to syncLog so devices/<legacy>/ is skipped as this device's
      // own; if it ever drifted from the pre-migration value, the old log
      // would be re-merged as a peer's on every tick.
      expect(legacySyncDeviceId, syncDeviceId);
    });
  });
}
