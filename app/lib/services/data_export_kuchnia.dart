/// The catering login inside the data export, as an encrypted section.
///
/// The password is never written in clear: the whole credential document is
/// sealed with AES-256-GCM under the newest key of the export keyring (see
/// `export_keyring.dart`), and the section names that key by `kid`. If the
/// keystore is unavailable the section is omitted and `kuchnia_skipped` says
/// so; there is no plaintext fallback.
library;

import 'dart:convert';

import 'package:diet_guard_app/services/export_crypto.dart';
import 'package:diet_guard_app/services/export_keyring.dart';
import 'package:diet_guard_app/services/kuchnia_credential_service.dart';

/// Export key holding the sealed login.
const kuchniaKey = 'kuchnia';

/// Export key explaining why [kuchniaKey] is absent.
const kuchniaSkippedKey = 'kuchnia_skipped';

/// A login in the file could not be restored; the rest of the import did run.
class KuchniaImportException implements Exception {
  /// Creates the exception; [reason] is `unknown_key` or `unreadable`.
  const KuchniaImportException(this.reason);

  /// Why the section was skipped.
  final String reason;

  @override
  String toString() => 'KuchniaImportException: $reason';
}

/// Top-level export entries for the login: the sealed box, or the skip flag.
Future<Map<String, Object?>> kuchniaExportEntries(ExportKeyring keyring) async {
  if (!KuchniaCredentialService.isInitialized ||
      !KuchniaCredentialService.isConfigured) {
    return {};
  }
  final ExportKey key;
  try {
    key = await keyring.ensureNewest();
  } on Object {
    return {kuchniaSkippedKey: 'keystore_unavailable'};
  }
  final clear = jsonEncode({
    'username': KuchniaCredentialService.username,
    'password': KuchniaCredentialService.password,
    't': KuchniaCredentialService.editedAt,
  });
  return {kuchniaKey: await encryptWithKey(clear, key)};
}

/// The key for [kid]; pulls the synced keyring once if it is not held yet.
Future<ExportKey?> _findKey(
  ExportKeyring keyring,
  String kid,
  Future<void> Function() pullKeys,
) async {
  final held = await keyring.byId(kid);
  if (held != null) return held;
  try {
    await pullKeys();
  } on Object {
    return null;
  }
  final pulled = await keyring.byId(kid);
  return pulled;
}

/// Opens the section from [root] and writes it only into an empty login.
///
/// Throws [KuchniaImportException] when it is present but cannot be opened.
/// A configured local login is never overwritten.
Future<void> importKuchnia(
  Map<dynamic, dynamic> root,
  ExportKeyring keyring,
  Future<void> Function() pullKeys,
) async {
  final box = root[kuchniaKey];
  if (box == null) return;
  final kid = envelopeKeyId(box);
  final Map<dynamic, dynamic> doc;
  try {
    final key = kid == null ? null : await _findKey(keyring, kid, pullKeys);
    if (key == null) throw const KuchniaImportException('unknown_key');
    doc = jsonDecode(await decryptWithKey(box, key)) as Map;
  } on KuchniaImportException {
    rethrow;
  } on Object {
    throw const KuchniaImportException('unreadable');
  }
  final username = doc['username'];
  final password = doc['password'];
  if (username is! String || password is! String) {
    throw const KuchniaImportException('unreadable');
  }
  if (!KuchniaCredentialService.isInitialized ||
      KuchniaCredentialService.isConfigured) {
    return;
  }
  await KuchniaCredentialService.instance.applySynced(
    username,
    password,
    doc['t'] is String ? doc['t'] as String : '',
  );
}
