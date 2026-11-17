/// The phone's side of the Claude relay: what the check-mark-gold button
/// sends and what comes back.
///
/// The transport (a request record synced to the PC, a worker that asks Claude
/// and logs the meal, the reply) is not here; the screen only talks to this
/// interface. See `docs/DOCS-claude-relay.md` for the wire.
///
/// A `Stream`, not a `Future`: the PC may be off, so a request can sit
/// [ClaudeRelayQueued] for hours before the same stream delivers
/// [ClaudeRelayLogged]. Terminal events end the stream; [ClaudeRelayQueued]
/// does not.
///
/// **The request id is the future entry id.** The worker logs the meal under
/// `ClaudeRelayRequest.requestId`, so the phone's copy (written from
/// [ClaudeRelayLogged]) and the PC's copy merge to one entry, and undo is a
/// tombstone on that id.
///
/// **Photos are transient input.** `photoJpeg` lives in memory for one send:
/// it is never stored on the phone, never put on a `FoodEntry`, and never part
/// of a synced meal record (`repo_invariants_test.dart` enforces it).
library;

import 'dart:typed_data';

import 'package:diet_guard_app/models/food_entry.dart';

/// One send: the text and/or photo, and the slot the meal belongs to.
class ClaudeRelayRequest {
  /// Creates a request; at least one of [text] and [photoJpeg] is non-empty.
  const ClaudeRelayRequest({
    required this.requestId,
    required this.slotMinute,
    this.text = '',
    this.photoJpeg,
  });

  /// A fresh uuid; becomes the logged entry's id.
  final String requestId;

  /// The slot minute the meal is logged against (the oldest due slot in due
  /// mode, else `slotForLog`).
  final int slotMinute;

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

/// Claude logged the meal (terminal). `entry.id == request.requestId`.
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
}

/// The stand-in until a transport is wired: every send fails closed.
class UnconfiguredClaudeRelayClient implements ClaudeRelayClient {
  /// Creates the stand-in.
  const UnconfiguredClaudeRelayClient();

  @override
  Stream<ClaudeRelayEvent> send(ClaudeRelayRequest request) =>
      Stream.value(const ClaudeRelayFailed('relay not configured'));
}

/// The client the screen uses unless it is handed one; `main.dart` assigns the
/// real transport.
ClaudeRelayClient claudeRelay = const UnconfiguredClaudeRelayClient();
