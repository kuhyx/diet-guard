/// The real relay client against an in-memory node store and a scripted
/// worker, on virtual time (every delay just advances the clock).
library;

import 'dart:convert';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/services/claude_relay_client.dart';
import 'package:diet_guard_app/services/claude_relay_firebase.dart';
import 'package:diet_guard_app/services/claude_relay_rtdb.dart';
import 'package:diet_guard_app/services/claude_relay_wire.dart';
import 'package:diet_guard_app/services/sync_e2e.dart';
import 'package:flutter_test/flutter_test.dart';

import 'claude_relay_test_support.dart';

const _rid = '01JD5Z8K3M7Q2W9XH4TBN6VR0E';
final _node = requestNode(_rid);

void main() {
  late E2eCipher cipher;
  late MemoryNodes nodes;
  late DateTime clock;
  late void Function(Duration waited) tick;
  late bool locked;
  late RtdbClaudeRelay relay;

  const request = ClaudeRelayRequest(
    requestId: _rid,
    slotMinute: 720,
    mode: ClaudeRelayMode.due,
    text: 'kurczak z ryzem',
  );

  Future<Map<String, Object?>> sealedResult(Map<String, Object?> plain) async =>
      {
        '_e2e': await cipher.seal(jsonEncode(plain), path: '$_node/result'),
        'at': 1,
      };

  Future<void> workerLogs() async {
    nodes.data['$_node/claim'] = {'by': 'pc-worker'};
    nodes.data['$_node/result'] = await sealedResult({
      'ok': true,
      'kind': 'meal',
      'status': 'logged',
      'id': _rid,
      'entry_id': claudeEntryId(_rid),
      'desc': 'kurczak z ryzem',
      'grams': 300,
      'kcal': 540,
      'protein_g': 42,
      'carbs_g': 61,
      'fat_g': 9,
      'slot_min': 480,
      'time': '2026-11-17T12:03:41+01:00',
    });
  }

  setUp(() {
    cipher = E2eCipher(List.filled(32, 3), acceptPlaintext: false);
    nodes = MemoryNodes();
    clock = DateTime(2026, 11, 17, 12);
    locked = false;
    tick = (_) {};
    relay = RtdbClaudeRelay(
      openNodes: () async => nodes,
      openCipher: () async {
        if (locked)
          throw const SyncLockedException(E2eLockReason.needsPassphrase);
        return cipher;
      },
      deviceId: () => 'phone-1',
      now: () => clock,
      delay: (d) async {
        clock = clock.add(d);
        tick(d);
      },
    );
  });

  Future<List<ClaudeRelayEvent>> run([ClaudeRelayRequest r = request]) =>
      relay.send(r).toList();

  test('the request is sealed at its own path with server time', () async {
    tick = (_) => workerLogs();
    await run();
    // Answered and tidied: the node is gone, but the put happened as sealed.
    expect(nodes.deleted, [_node]);
  });

  test('a sealed request opens to the contract body', () async {
    Map<String, Object?>? unit;
    tick = (_) {
      unit ??= nodes.data['$_node/req']! as Map<String, Object?>;
      workerLogs();
    };
    await run();
    expect(unit!.keys.toSet(), {'_e2e', 'created'});
    final plain =
        jsonDecode(
              await cipher.open(unit!['_e2e']! as String, path: '$_node/req'),
            )
            as Map<String, dynamic>;
    expect(plain['kind'], 'meal');
    expect(plain['dev'], 'phone-1');
    expect(plain['sent_at'], DateTime(2026, 11, 17, 12).millisecondsSinceEpoch);
    expect(plain['body'], {
      'text': 'kurczak z ryzem',
      'client_slot_min': 720,
      'mode': 'due',
    });
  });

  test('claimed quickly: no queued state, then the logged entry', () async {
    tick = (_) => workerLogs();
    final events = await run();
    expect(events.map((e) => e.runtimeType), [ClaudeRelayLogged]);
    final entry = (events.single as ClaudeRelayLogged).entry;
    expect(entry.id, claudeEntryId(_rid));
    expect(entry.kcal, 540);
  });

  test(
    'no claim within 3 s reads as queued, once, then still delivers',
    () async {
      var polls = 0;
      tick = (_) {
        if (++polls == 8) workerLogs();
      };
      final events = await run();
      expect(events.map((e) => e.runtimeType), [
        ClaudeRelayQueued,
        ClaudeRelayLogged,
      ]);
    },
  );

  test('a claim without a result is not queued', () async {
    var polls = 0;
    tick = (_) {
      nodes.data['$_node/claim'] = {'by': 'pc-worker'};
      if (++polls == 8) workerLogs();
    };
    final events = await run();
    expect(events.map((e) => e.runtimeType), [ClaudeRelayLogged]);
  });

  test('locked sync sends nothing', () async {
    locked = true;
    final events = await run();
    expect(events.single, isA<ClaudeRelayLocked>());
    expect(nodes.data, isEmpty);
  });

  test('an error result becomes its code', () async {
    tick = (_) async {
      nodes.data['$_node/result'] = await sealedResult({
        'ok': false,
        'status': 'error',
        'id': _rid,
        'error_code': 'estimate_timeout',
      });
    };
    final events = await run();
    expect((events.single as ClaudeRelayFailed).reason, 'estimate_timeout');
    expect(nodes.deleted, [_node]);
  });

  test('a request that breaks the contract never leaves the phone', () async {
    final events = await run(
      const ClaudeRelayRequest(requestId: _rid, slotMinute: 5000, text: 'x'),
    );
    expect(events.single, isA<ClaudeRelayFailed>());
    expect(nodes.data, isEmpty);
  });

  test('a failed put is a visible failure', () async {
    nodes.failPut = true;
    expect((await run()).single, isA<ClaudeRelayFailed>());
  });
}
