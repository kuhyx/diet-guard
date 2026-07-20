/// Keystore-backed [TokenVault] used on Android.
library;

import 'package:diet_guard_app/services/token_vault.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keeps the token in the OS keystore (Android Keystore) via
/// [FlutterSecureStorage].
///
/// Default options keep us off the deprecated `encryptedSharedPreferences`
/// path on Android.
class SecureStorageTokenVault implements TokenVault {
  /// Creates a vault over [storage].
  const SecureStorageTokenVault({this.storage = const FlutterSecureStorage()});

  /// The wrapped keystore. Injectable so a test can supply a fake.
  final FlutterSecureStorage storage;

  /// Key for the token inside the OS keystore.
  static const _secureToken = 'sync.token';

  @override
  bool get exposesTokenValue => true;

  @override
  Future<String> read() async {
    try {
      return await storage.read(key: _secureToken) ?? '';
    } on PlatformException {
      // No secret service available -- the caller falls back to the legacy
      // plaintext copy in SharedPreferences.
      return '';
    }
  }

  @override
  Future<bool> write(String token) async {
    try {
      if (token.isEmpty) {
        await storage.delete(key: _secureToken);
      } else {
        await storage.write(key: _secureToken, value: token);
      }
      return true;
    } on PlatformException {
      return false;
    }
  }
}

/// Opens the platform token vault.
TokenVault openTokenVault() => const SecureStorageTokenVault();
