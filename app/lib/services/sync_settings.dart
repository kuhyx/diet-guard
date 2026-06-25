/// Locally-stored GitHub sync configuration, ported from `~/todo`'s
/// `sync/sync_settings.dart`, including the OAuth device-flow fields: the
/// "Connect GitHub" button is the primary path, with a pasted PAT kept as a
/// manual fallback.
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
    this.clientId = '',
  });

  /// The repo owner/org (e.g. `"kuhyx"`).
  final String owner;

  /// The repo name (e.g. `"diet-guard-sync"`).
  final String repo;

  /// A GitHub PAT with contents read/write on [owner]/[repo].
  final String token;

  /// GitHub OAuth App client id used by the device-flow "Connect" button.
  /// Not a secret (device flow needs no client secret), so it is safe to
  /// ship as a compile-time default and commit to source — see
  /// [defaultClientId].
  final String clientId;

  /// The app's own GitHub OAuth App (device-flow enabled) client id, baked
  /// in so "Connect GitHub" works with zero setup. Registered 2026-06-23 at
  /// github.com/settings/developers, device flow enabled — distinct from
  /// the sibling notes app's OAuth App, which belongs to a different
  /// product.
  static const defaultClientId = 'Ov23li8wIQBai3qtbsqa';

  /// True when enough is set to attempt a sync.
  bool get isConfigured =>
      owner.isNotEmpty && repo.isNotEmpty && token.isNotEmpty;

  /// True when device-flow "Connect GitHub" can be offered.
  bool get canUseDeviceFlow => clientId.isNotEmpty;

  static const _kOwner = 'sync.owner';
  static const _kRepo = 'sync.repo';
  static const _kClientId = 'sync.clientId';
  // Legacy plaintext location for the token; read-only now and removed once
  // the token has been migrated into secure storage.
  static const _kToken = 'sync.token';

  /// Key for the token inside the OS keystore.
  static const _secureToken = 'sync.token';

  /// Default options keep us off the deprecated `encryptedSharedPreferences`
  /// path on Android and use libsecret on Linux.
  static const _secure = FlutterSecureStorage();

  /// Loads settings, defaulting the owner/repo to `kuhyx/diet-guard-sync`
  /// (matching the PC's `SYNC_REPO_OWNER`/`SYNC_REPO_NAME` constants) and the
  /// client id to the baked-in [defaultClientId], so a fresh install needs
  /// only "Connect GitHub" (once an OAuth App is registered) or a pasted PAT.
  static Future<SyncSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return SyncSettings(
      owner: prefs.getString(_kOwner) ?? 'kuhyx',
      repo: prefs.getString(_kRepo) ?? 'diet-guard-sync',
      token: await _loadToken(prefs),
      clientId: prefs.getString(_kClientId) ?? defaultClientId,
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
    await prefs.setString(_kClientId, clientId);
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
  SyncSettings copyWith({
    String? owner,
    String? repo,
    String? token,
    String? clientId,
  }) {
    return SyncSettings(
      owner: owner ?? this.owner,
      repo: repo ?? this.repo,
      token: token ?? this.token,
      clientId: clientId ?? this.clientId,
    );
  }
}
