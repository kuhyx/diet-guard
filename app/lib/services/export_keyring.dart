/// The export keyring: random 256-bit AES keys that unlock data exports.
///
/// Keys live in the OS keystore and also sync between devices as the
/// `export_keys` document (see `export_keyring_sync.dart`), so an export made
/// on one device opens on another. It is a keyring, not a single key: a key
/// is never deleted or overwritten, each id is its own record, and two
/// devices that mint a key at the same moment both keep both.
///
/// The synced copy is end-to-end encrypted under the shared crdt-sync
/// passphrase (`sync_e2e.dart`), on `diet-guard-sync/devices-e2e`. The old
/// plaintext `diet-guard-sync/devices/<id>/export_keys.json` nodes are
/// copied over once and then neither read nor written by this app.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crdt_sync/crdt_sync.dart';

/// Keystore entry holding the whole ring as JSON.
const keyringStorageKey = 'diet_guard.export_keyring';

final _kidShape = RegExp(r'^[0-9a-f]{16}$');
const _keyBytes = 32;

/// One export key.
class ExportKey {
  /// Creates a key; [kid] is 16 hex chars, [bytes] 32 bytes.
  const ExportKey(this.kid, this.bytes, this.createdAt);

  /// Random id written into every export sealed with this key.
  final String kid;

  /// The AES-256 key.
  final List<int> bytes;

  /// When it was minted (UTC); the newest key signs new exports.
  final DateTime createdAt;

  /// True when [kid] and [bytes] have the shape a real key has.
  bool get isWellFormed => _kidShape.hasMatch(kid) && bytes.length == _keyBytes;
}

/// A keyring over an injected keystore.
///
/// Reads and writes throw when the keystore is unavailable or holds garbage;
/// callers treat that as "no keyring" and never fall back to plaintext. A
/// garbled ring is not replaced, since that would destroy the keys in it.
class ExportKeyring {
  /// Creates a ring over [read]/[write] (the OS keystore in the app).
  ExportKeyring({required this.read, required this.write});

  /// Reads a keystore entry, or null when absent.
  final SecretReader read;

  /// Writes a keystore entry.
  final SecretWriter write;

  /// Every key held, in no particular order.
  Future<List<ExportKey>> all() async {
    final raw = await read(keyringStorageKey);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw StateError('export keyring is corrupt');
    return [
      for (final MapEntry(key: kid, value: entry) in decoded.entries)
        ExportKey(
          kid as String,
          base64Decode((entry as Map)['k'] as String),
          DateTime.parse(entry['t'] as String).toUtc(),
        ),
    ];
  }

  /// The key with id [kid], or null when this device does not hold it.
  Future<ExportKey?> byId(String kid) async {
    for (final key in await all()) {
      if (key.kid == kid) return key;
    }
    return null;
  }

  /// The newest key, minting and storing one if the ring is empty.
  Future<ExportKey> ensureNewest() async {
    var keys = await all();
    if (keys.isEmpty) {
      final rng = Random.secure();
      final fresh = ExportKey(
        [
          for (var i = 0; i < 8; i++) rng.nextInt(256),
        ].map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        [for (var i = 0; i < _keyBytes; i++) rng.nextInt(256)],
        DateTime.now().toUtc(),
      );
      await mergeKeys([fresh]);
      keys = [fresh];
    }
    return keys.reduce(
      (a, b) =>
          a.createdAt.isAfter(b.createdAt) ||
              (a.createdAt == b.createdAt && a.kid.compareTo(b.kid) > 0)
          ? a
          : b,
    );
  }

  /// Adds the well-formed keys whose id is not held yet; never overwrites.
  Future<void> mergeKeys(Iterable<ExportKey> incoming) async {
    final held = {for (final key in await all()) key.kid: key};
    final before = held.length;
    for (final key in incoming) {
      if (key.isWellFormed) held.putIfAbsent(key.kid, () => key);
    }
    if (held.length == before) return;
    await write(
      keyringStorageKey,
      jsonEncode({
        for (final key in held.values)
          key.kid: {
            'k': base64Encode(key.bytes),
            't': key.createdAt.toIso8601String(),
          },
      }),
    );
  }
}
