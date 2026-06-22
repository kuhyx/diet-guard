/// Locally-stored GitHub sync configuration, ported from `~/todo`'s
/// `sync/sync_settings.dart` -- with the OAuth device-flow fields dropped:
/// the phone leans on a pasted PAT instead (the plan's call to pick
/// "whichever is less code", and pasting is strictly less code here).
library;

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The GitHub token is kept in the OS keystore (Android Keystore / libsecret)
/// via [flutter_secure_storage]; only the non-secret owner/repo live in
/// `SharedPreferences`. Older builds stored the token in plaintext prefs;
/// [load]/[save] migrate it transparently and never drop the plaintext copy
/// until a secure write is confirmed (so we degrade to -- never below -- the
/// old behaviour when no secret service is available).
class SyncSettings {
  /// Creates a [SyncSettings] from its owner/repo/token.
  const SyncSettings({
    required this.owner,
    required this.repo,
    required this.token,
  });

  /// The repo owner/org (e.g. `"kuhyx"`).
  final String owner;

  /// The repo name (e.g. `"diet-guard-sync"`).
  final String repo;

  /// A GitHub PAT with contents read/write on [owner]/[repo].
  final String token;

  /// True when enough is set to attempt a sync.
  bool get isConfigured =>
      owner.isNotEmpty && repo.isNotEmpty && token.isNotEmpty;

  static const _kOwner = 'sync.owner';
  static const _kRepo = 'sync.repo';
  // Legacy plaintext location for the token; read-only now and removed once
  // the token has been migrated into secure storage.
  static const _kToken = 'sync.token';

  /// Key for the token inside the OS keystore.
  static const _secureToken = 'sync.token';

  /// Default options keep us off the deprecated `encryptedSharedPreferences`
  /// path on Android and use libsecret on Linux.
  static const _secure = FlutterSecureStorage();

  /// Loads settings, defaulting the owner/repo to `kuhyx/diet-guard-sync`
  /// (matching the PC's `SYNC_REPO_OWNER`/`SYNC_REPO_NAME` constants) so a
  /// fresh install needs only a pasted PAT.
  static Future<SyncSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return SyncSettings(
      owner: prefs.getString(_kOwner) ?? 'kuhyx',
      repo: prefs.getString(_kRepo) ?? 'diet-guard-sync',
      token: await _loadToken(prefs),
    );
  }

  /// Reads the token, preferring the keystore and falling back to the legacy
  /// plaintext value. A legacy value is migrated into the keystore on read,
  /// but only dropped from prefs once that secure write succeeds.
  static Future<String> _loadToken(SharedPreferences prefs) async {
    String? secure;
    try {
      secure = await _secure.read(key: _secureToken);
    } on PlatformException {
      // No secret service available -- fall back to the legacy plaintext copy.
      secure = null;
    }
    if (secure != null && secure.isNotEmpty) return secure;

    final legacy = prefs.getString(_kToken) ?? '';
    if (legacy.isNotEmpty && await _writeSecureToken(legacy)) {
      await prefs.remove(_kToken);
    }
    return legacy;
  }

  /// Persists [owner]/[repo] to prefs and [token] to the keystore (or
  /// plaintext prefs as a fallback -- see [_loadToken]).
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kOwner, owner);
    await prefs.setString(_kRepo, repo);
    // Confirm-before-delete: only remove the plaintext copy once the keystore
    // write succeeds; otherwise keep persisting it to prefs as before.
    if (await _writeSecureToken(token)) {
      await prefs.remove(_kToken);
    } else {
      await prefs.setString(_kToken, token);
    }
  }

  /// Writes [token] to the keystore (deleting the entry when empty). Returns
  /// false if the platform secret service is unavailable.
  static Future<bool> _writeSecureToken(String token) async {
    try {
      if (token.isEmpty) {
        await _secure.delete(key: _secureToken);
      } else {
        await _secure.write(key: _secureToken, value: token);
      }
      return true;
    } on PlatformException {
      return false;
    }
  }

  /// Returns a copy of this with only the given fields replaced.
  SyncSettings copyWith({String? owner, String? repo, String? token}) {
    return SyncSettings(
      owner: owner ?? this.owner,
      repo: repo ?? this.repo,
      token: token ?? this.token,
    );
  }
}
