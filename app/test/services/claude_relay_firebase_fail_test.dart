/// The real relay client's failure paths and `cancel`, on virtual time.
library;

import 'dart:convert';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/services/claude_relay_client.dart';
import 'package:diet_guard_app/services/claude_relay_firebase.dart';
import 'package:diet_guard_app/services/claude_relay_rtdb.dart';
import 'package:diet_guard_app/services/claude_relay_wire.dart';
import 'package:flutter_test/flutter_test.dart';

import 'claude_relay_test_support.dart';

const _rid = '01JD5Z8K3M7Q2W9XH4TBN6VR0E';
final _node = requestNode(_rid);

void main() {
  late E2eCipher cipher;
  late MemoryNodes nodes;
  late DateTime clock;
  late void Function() tick;
  late RtdbClaudeRelay relay;

  const request = ClaudeRelayRequest(
    requestId: _rid,
    slotMinute: 720,
    text: 'kurczak',
  );

  Future<void> workerLogs() async {
    nodes.data['$_node/claim'] = {'by': 'pc-worker'};
    nodes.data['$_node/result'] = {
      '_e2e': await cipher.seal(
        jsonEncode({
          'ok': true,
          'status': 'logged',
          'id': _rid,
          'entry_id': claudeEntryId(_rid),
          'desc': 'kurczak',
          'grams': 1,
          'kcal': 1,
          'protein_g': 1,
          'carbs_g': 1,
          'fat_g': 1,
          'slot_min': 480,
          'time': '2026-11-17T12:03:41+01:00',
        }),
        path: '$_node/result',
      ),
      'at': 1,
    };
  }

  setUp(() {
    cipher = E2eCipher(List.filled(32, 3), acceptPlaintext: false);
    nodes = MemoryNodes();
    clock = DateTime(2026, 11, 17, 12);
    tick = () {};
    relay = RtdbClaudeRelay(
      openNodes: () async => nodes,
      openCipher: () async => cipher,
      deviceId: () => 'phone-1',
      now: () => clock,
      delay: (d) async {
        clock = clock.add(d);
        tick();
      },
    );
  });

  test('one bad poll is tolerated, three in a row are not', () async {
    nodes.failReads = 1;
    tick = workerLogs;
    expect(
      (await relay.send(request).toList()).single,
      isA<ClaudeRelayLogged>(),
    );

    nodes.data.clear();
    nodes.failReads = 3;
    expect(
      (await relay.send(request).toList()).single,
      isA<ClaudeRelayFailed>(),
    );
  });

  test('no answer within the wait fails closed, after queued', () async {
    final events = await relay.send(request).toList();
    expect(events.first, isA<ClaudeRelayQueued>());
    expect((events.last as ClaudeRelayFailed).reason, 'no answer in time');
  });

  test('a node that disappears fails closed', () async {
    tick = nodes.data.clear;
    final events = await relay.send(request).toList();
    expect((events.last as ClaudeRelayFailed).reason, 'request vanished');
  });

  test(
    'cancel removes an unclaimed request and refuses a claimed one',
    () async {
      await nodes.put('$_node/req', {'_e2e': 'x'});
      expect(await relay.cancel(_rid), isTrue);
      expect(nodes.data, isEmpty);

      nodes.data['$_node/req'] = {'_e2e': 'x'};
      nodes.data['$_node/claim'] = {'by': 'pc-worker'};
      expect(await relay.cancel(_rid), isFalse);
      expect(nodes.data, isNotEmpty);
    },
  );

  test('cancel is false when the transport is down', () async {
    final down = RtdbClaudeRelay(
      openNodes: () async => throw const RelayTransportError('offline'),
      openCipher: () async => cipher,
      deviceId: () => 'p',
    );
    expect(await down.cancel(_rid), isFalse);
  });
}
