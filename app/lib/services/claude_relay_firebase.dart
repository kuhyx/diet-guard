/// The real [ClaudeRelayClient]: requests and answers through Firebase RTDB,
/// end-to-end encrypted, served by the PC's `claude-worker`.
///
/// One send: seal the request with the existing E2E key (header
/// `diet-guard-sync/e2e`, the key the log sync already uses), PUT it under
/// `requests/<ULID>/req`, then watch the node. No claim after
/// [claimWindow] means the PC is offline: [ClaudeRelayQueued], and the same
/// stream keeps waiting. The worker's sealed `result` becomes
/// [ClaudeRelayLogged] or [ClaudeRelayFailed], and the phone then deletes the
/// request node as `docs/DOCS-claude-relay.md` asks.
///
/// **Fail closed, visibly.** A locked key is [ClaudeRelayLocked]; a request
/// that breaks the contract, a transport that keeps failing, a result that
/// does not open or carries an entry id the phone did not derive, and a wait
/// past [maxWait] are all [ClaudeRelayFailed]. Nothing is ever shown as
/// logged unless a valid sealed result says so.
///
/// Polling, not a stream: the node's child keys (no values, so the photo is
/// never re-read) are listed every second, then every 5 s once the wait is
/// long. The phone is a foreground client here; a queued request that outlives
/// the screen reaches the log through the normal sync instead.
library;

import 'dart:async';
import 'dart:developer';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/services/claude_relay_client.dart';
import 'package:diet_guard_app/services/claude_relay_rtdb.dart';
import 'package:diet_guard_app/services/claude_relay_wire.dart';
import 'package:diet_guard_app/services/firebase_backend.dart';
import 'package:diet_guard_app/services/firebase_client.dart';
import 'package:diet_guard_app/services/sync_device_id.dart';
import 'package:diet_guard_app/services/sync_e2e.dart';

const _fastPoll = Duration(seconds: 1);
const _slowPoll = Duration(seconds: 5);
const _slowAfter = Duration(seconds: 30);
const _maxPollFailures = 3;

/// [ClaudeRelayClient] over RTDB.
class RtdbClaudeRelay implements ClaudeRelayClient {
  /// Creates the client; every dependency is injectable for tests.
  RtdbClaudeRelay({
    required this.openNodes,
    required this.openCipher,
    required this.deviceId,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
    this.claimWindow = const Duration(seconds: 3),
    this.maxWait = const Duration(minutes: 15),
  }) : _now = now ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed;

  /// The app's real transport: Firebase session, E2E key from the keystore.
  ///
  /// Everything resolves at send time, so building it in `main` costs nothing
  /// and a device that signs in later just works.
  factory RtdbClaudeRelay.firebase() {
    FirebaseRestClient? client;
    Future<FirebaseRestClient> session() async => client ??=
        await openFirebase() ??
        (throw const RelayTransportError('not signed in to Firebase'));
    return RtdbClaudeRelay(
      openNodes: () async {
        final auth = (await session()).auth;
        return RtdbNodes(
          databaseUrl: kProject.databaseUrl,
          idToken: auth.idToken,
        );
      },
      openCipher: () => session().then(openDietGuardCipher),
      deviceId: () => currentSyncDeviceId,
    );
  }

  /// Opens the node access, throwing [RelayTransportError] when unavailable.
  final Future<RelayNodes> Function() openNodes;

  /// Opens the E2E cipher, throwing [SyncLockedException] when locked.
  final Future<E2eCipher> Function() openCipher;

  /// This phone's sync device id, sent as `dev`.
  final String Function() deviceId;

  /// How long an unclaimed request waits before it reads as queued.
  final Duration claimWindow;

  /// How long one send waits for an answer before it fails.
  final Duration maxWait;

  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;

  @override
  Stream<ClaudeRelayEvent> send(ClaudeRelayRequest request) async* {
    final problem = relayBodyProblem(relayBody(request));
    if (problem != null) {
      yield ClaudeRelayFailed('bad request: $problem');
      return;
    }
    final RelayNodes nodes;
    final E2eCipher cipher;
    try {
      cipher = await openCipher();
      nodes = await openNodes();
      final unit = await sealRequest(
        cipher,
        request,
        device: deviceId(),
        nowMs: _now().millisecondsSinceEpoch,
      );
      await nodes.put('${requestNode(request.requestId)}/req', unit);
    } on SyncLockedException {
      yield const ClaudeRelayLocked();
      return;
    } on Object catch (error, stackTrace) {
      log(
        'claude relay send failed',
        level: 1000,
        error: error,
        stackTrace: stackTrace,
      );
      yield const ClaudeRelayFailed('could not send');
      return;
    }
    yield* _await(nodes, cipher, request.requestId);
  }

  Stream<ClaudeRelayEvent> _await(
    RelayNodes nodes,
    E2eCipher cipher,
    String rid,
  ) async* {
    final node = requestNode(rid);
    final started = _now();
    var queued = false;
    var failures = 0;
    while (true) {
      final waited = _now().difference(started);
      if (waited > maxWait) {
        yield const ClaudeRelayFailed('no answer in time');
        return;
      }
      try {
        final keys = await nodes.keys(node);
        failures = 0;
        if (keys.contains('result')) {
          final result = await openResult(
            cipher,
            rid,
            await nodes.get('$node/result'),
          );
          await _tidy(nodes, node);
          yield result;
          return;
        }
        if (keys.isEmpty) {
          yield const ClaudeRelayFailed('request vanished');
          return;
        }
        if (!queued && !keys.contains('claim') && waited >= claimWindow) {
          queued = true;
          yield const ClaudeRelayQueued();
        }
      } on Object catch (error, stackTrace) {
        log(
          'claude relay poll failed',
          level: 900,
          error: error,
          stackTrace: stackTrace,
        );
        if (++failures >= _maxPollFailures) {
          yield const ClaudeRelayFailed('connection lost');
          return;
        }
      }
      await _delay(waited < _slowAfter ? _fastPoll : _slowPoll);
    }
  }

  /// Deletes the answered request node. Best effort: the worker also sweeps
  /// answered nodes after 24 h, so a failure costs nothing but a few bytes.
  Future<void> _tidy(RelayNodes nodes, String node) async {
    try {
      await nodes.delete(node);
    } on Object catch (error) {
      log('claude relay cleanup failed', level: 900, error: error);
    }
  }

  @override
  Future<bool> cancel(String requestId) async {
    try {
      return await (await openNodes()).deleteUnclaimed(requestNode(requestId));
    } on Object catch (error) {
      log('claude relay cancel failed', level: 900, error: error);
      return false;
    }
  }
}
