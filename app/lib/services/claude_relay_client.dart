/// The phone's side of the Claude relay: what the sparkle button sends and
/// what comes back.
///
/// The screen only talks to this interface; `claude_relay_firebase.dart` is the
/// real transport (Firebase RTDB, end-to-end encrypted) and
/// `claude_relay_fake.dart` the test double. The wire is
/// `docs/DOCS-claude-relay.md` plus `tests/fixtures/claude_relay_contract.json`.
///
/// A `Stream`, not a `Future`: the PC may be off, so a request can sit
/// [ClaudeRelayQueued] for hours before the same stream delivers
/// [ClaudeRelayLogged]. Terminal events end the stream; [ClaudeRelayQueued]
/// does not.
///
/// **The request id is a ULID** (`rtdb_relay` never serves another key shape)
/// and **the entry id is derived from it**: `uuid5(namespace, rid)`, computed
/// here by [claudeEntryId] exactly as the PC does. So the phone knows the id
/// of the entry before Claude has answered, a logged result is checked against
/// it, and undo is a tombstone on that id.
///
/// **Photos are transient input.** `photoJpeg` lives in memory for one send:
/// it is never stored on the phone, never put on a `FoodEntry`, and never part
/// of a synced meal record (`repo_invariants_photo_test.dart` enforces it).
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:uuid/uuid.dart';

/// The UUID namespace the PC derives entry ids in (`entry_id_namespace` in the
/// contract fixture).
const claudeEntryNamespace = '5d9c1a40-6f0e-5c3e-9b57-d1e7a3c0b2f4';

/// The id of the entry the PC logs for request [requestId].
String claudeEntryId(String requestId) =>
    const Uuid().v5(claudeEntryNamespace, requestId);

const _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// A fresh ULID: 48 bits of [now] in ms, then 80 random bits, 26 characters of
/// Crockford base32. [random] is injectable for tests.
String newRequestId({DateTime? now, Random? random}) {
  final rng = random ?? Random.secure();
  var ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final out = List<String>.filled(26, '0');
  for (var i = 9; i >= 0; i--) {
    out[i] = _crockford[ms % 32];
    ms ~/= 32;
  }
  for (var i = 10; i < 26; i++) {
    out[i] = _crockford[rng.nextInt(32)];
  }
  return out.join();
}

/// How the PC picks the slot: the oldest due slot, or the nearest to
/// [ClaudeRelayRequest.slotMinute].
enum ClaudeRelayMode {
  /// The phone is in due mode.
  due,

  /// Nothing is due.
  normal,
}

/// One send: the text and/or photo, and the slot the meal belongs to.
class ClaudeRelayRequest {
  /// Creates a request; at least one of [text] and [photoJpeg] is non-empty.
  const ClaudeRelayRequest({
    required this.requestId,
    required this.slotMinute,
    this.mode = ClaudeRelayMode.normal,
    this.text = '',
    this.photoJpeg,
  });

  /// A ULID (see [newRequestId]); the entry id is [claudeEntryId] of it.
  final String requestId;

  /// The slot minute the phone would log against now (`client_slot_min`).
  final int slotMinute;

  /// Whether the phone is in due mode.
  final ClaudeRelayMode mode;

  /// What the user typed, trimmed; may be empty when a photo is attached.
  final String text;

  /// The photo as a JPEG of at most 1024 px, or null.
  final Uint8List? photoJpeg;
}

/// What the relay reports about one [ClaudeRelayRequest].
sealed class ClaudeRelayEvent {
  const ClaudeRelayEvent();
}

/// The PC is offline; the request is stored and will run later (not terminal).
final class ClaudeRelayQueued extends ClaudeRelayEvent {
  /// Creates the event.
  const ClaudeRelayQueued();
}

/// Claude logged the meal (terminal). `entry.id == claudeEntryId(rid)`.
final class ClaudeRelayLogged extends ClaudeRelayEvent {
  /// Creates the event for [entry].
  const ClaudeRelayLogged(this.entry);

  /// The entry the worker wrote.
  final FoodEntry entry;
}

/// Sync is locked (no passphrase), so nothing can be sent (terminal).
final class ClaudeRelayLocked extends ClaudeRelayEvent {
  /// Creates the event.
  const ClaudeRelayLocked();
}

/// The send failed (terminal); [reason] is for logs, never painted.
final class ClaudeRelayFailed extends ClaudeRelayEvent {
  /// Creates the event.
  const ClaudeRelayFailed(this.reason);

  /// Why it failed.
  final String reason;
}

/// Sends a meal to Claude through the relay.
abstract interface class ClaudeRelayClient {
  /// Sends [request]; the stream carries zero or more [ClaudeRelayQueued]
  /// then one terminal event, and never throws (failures are events).
  Stream<ClaudeRelayEvent> send(ClaudeRelayRequest request);

  /// Withdraws [requestId] if no worker has claimed it yet; true when it is
  /// gone. False means it was already claimed (or the call failed), and the
  /// meal will be logged: the stream keeps listening so the row still shows.
  Future<bool> cancel(String requestId);
}

/// The stand-in until a transport is wired: every send fails closed.
class UnconfiguredClaudeRelayClient implements ClaudeRelayClient {
  /// Creates the stand-in.
  const UnconfiguredClaudeRelayClient();

  @override
  Stream<ClaudeRelayEvent> send(ClaudeRelayRequest request) =>
      Stream.value(const ClaudeRelayFailed('relay not configured'));

  @override
  Future<bool> cancel(String requestId) async => true;
}

/// The client the screen uses unless it is handed one; `main.dart` assigns the
/// real transport.
ClaudeRelayClient claudeRelay = const UnconfiguredClaudeRelayClient();
