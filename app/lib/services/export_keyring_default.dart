/// The app's real export keyring and its on-demand key pull.
library;

import 'dart:developer';

import 'package:diet_guard_app/services/export_keyring.dart';
import 'package:diet_guard_app/services/export_keyring_sync.dart';
import 'package:diet_guard_app/services/firebase_client.dart';
import 'package:diet_guard_app/services/github_client_factory.dart';
import 'package:diet_guard_app/services/sync_device_id.dart';
import 'package:diet_guard_app/services/sync_e2e.dart';
import 'package:diet_guard_app/services/sync_settings.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Platform-channel code (keystore, network); the logic it wires lives in
// export_keyring*.dart and is covered there.
// coverage:ignore-start
const _secure = FlutterSecureStorage();

/// The keyring backed by the OS keystore.
ExportKeyring defaultKeyring() => ExportKeyring(
  read: (key) => _secure.read(key: key),
  write: (key, value) => _secure.write(key: key, value: value),
);

/// One sync pull of the keyring, for an import that met an unknown key id.
///
/// Best effort: offline or signed out just leaves the key unknown, and the
/// import reports that.
Future<void> pullExportKeys() async {
  try {
    final client = createGitHubClient(await SyncSettings.load());
    try {
      await syncExportKeys(
        await openDietGuardStore(await syncBackend(client)),
        keyring: defaultKeyring(),
        devicesDir: syncDevicesDir,
      );
    } finally {
      client.close();
    }
  } on Object catch (error, stackTrace) {
    log(
      'export key pull failed',
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
  }
}
// coverage:ignore-end
