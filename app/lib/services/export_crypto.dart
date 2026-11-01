/// AES-256-GCM sealing for the data export, keyed by an [ExportKey].
///
/// Pure Dart (`package:cryptography`), no `dart:io`, so it runs on Android and
/// in the web build alike. Nothing here falls back to plaintext: any failure
/// is an [ExportCryptoException].
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:diet_guard_app/services/export_keyring.dart';

/// The `enc` marker of the only envelope layout this build reads and writes.
const encryptionVersion = 'v2';

const _nonceBytes = 12;
const _macBytes = 16;

/// Binds a ciphertext to its role and key id, so it cannot be replayed.
List<int> _aad(String kid) =>
    utf8.encode('diet_guard_export:kuchnia:$encryptionVersion:$kid');

/// Wrong key, tampered or malformed envelope.
class ExportCryptoException implements Exception {
  /// Creates the exception.
  const ExportCryptoException(this.message);

  /// What was wrong; never contains key material.
  final String message;

  @override
  String toString() => 'ExportCryptoException: $message';
}

/// Seals [plaintext] under [key] with a fresh random nonce.
///
/// `ciphertext` is the encrypted bytes followed by the 16-byte GCM tag.
Future<Map<String, Object?>> encryptWithKey(
  String plaintext,
  ExportKey key,
) async {
  final rng = Random.secure();
  final nonce = Uint8List.fromList([
    for (var i = 0; i < _nonceBytes; i++) rng.nextInt(256),
  ]);
  final box = await AesGcm.with256bits().encrypt(
    utf8.encode(plaintext),
    secretKey: SecretKey(key.bytes),
    nonce: nonce,
    aad: _aad(key.kid),
  );
  return {
    'enc': encryptionVersion,
    'alg': 'AES-256-GCM',
    'kid': key.kid,
    'nonce': base64Encode(nonce),
    'ciphertext': base64Encode([...box.cipherText, ...box.mac.bytes]),
  };
}

/// The key id an envelope was sealed with, or null when it has none.
String? envelopeKeyId(Object? envelope) {
  if (envelope is! Map || envelope['enc'] != encryptionVersion) return null;
  final kid = envelope['kid'];
  return kid is String ? kid : null;
}

/// Opens an [encryptWithKey] envelope; throws [ExportCryptoException].
Future<String> decryptWithKey(Object? envelope, ExportKey key) async {
  final Uint8List nonce;
  final Uint8List sealed;
  try {
    final map = envelope! as Map;
    if (envelopeKeyId(map) != key.kid) throw const FormatException('kid');
    nonce = base64Decode(map['nonce']! as String);
    sealed = base64Decode(map['ciphertext']! as String);
  } on Object {
    throw const ExportCryptoException('malformed envelope');
  }
  if (nonce.length != _nonceBytes || sealed.length < _macBytes) {
    throw const ExportCryptoException('malformed envelope');
  }
  final cut = sealed.length - _macBytes;
  try {
    final clear = await AesGcm.with256bits().decrypt(
      SecretBox(
        sealed.sublist(0, cut),
        nonce: nonce,
        mac: Mac(sealed.sublist(cut)),
      ),
      secretKey: SecretKey(key.bytes),
      aad: _aad(key.kid),
    );
    return utf8.decode(clear);
  } on Object {
    throw const ExportCryptoException('wrong key or tampered data');
  }
}
