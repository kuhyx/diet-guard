/// The relay wire against `tests/fixtures/claude_relay_contract.json`, the
/// same file the Python worker's tests read. Seal and open go through the
/// fixture's key, so a drift on either side fails here.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/services/claude_relay_client.dart';
import 'package:diet_guard_app/services/claude_relay_wire.dart';
import 'package:diet_guard_app/services/sync_e2e.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _fixture() {
  var dir = Directory.current;
  while (!File(
    '${dir.path}/tests/fixtures/claude_relay_contract.json',
  ).existsSync()) {
    dir = dir.parent;
  }
  return jsonDecode(
        File(
          '${dir.path}/tests/fixtures/claude_relay_contract.json',
        ).readAsStringSync(),
      )
      as Map<String, dynamic>;
}

List<int> _hex(String s) => [
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
];

void main() {
  final fx = _fixture();
  final rid = fx['rid'] as String;
  late E2eCipher cipher;

  setUp(() async {
    // The fixture key is the cipher key itself, as `E2eKey.cipher()` hands
    // it out on both devices (no further derivation).
    cipher = E2eCipher(_hex(fx['key_hex'] as String), acceptPlaintext: false);
  });

  test('root, header and entry id agree with the contract', () {
    expect(relayRoot, fx['root']);
    // The relay reuses the diet-guard header: same passphrase, same salt.
    expect(E2eLayout.of('diet-guard-sync/claude').e2ePath, fx['header_path']);
    expect(E2eLayout.of(legacyDevicesDir).e2ePath, fx['header_path']);
    expect(claudeEntryNamespace, fx['entry_id_namespace']);
    expect(claudeEntryId(rid), fx['entry_id']);
  });

  test('a ULID the phone makes is one the relay serves', () {
    final id = newRequestId();
    expect(RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$').hasMatch(id), isTrue);
    expect(newRequestId(), isNot(id));
  });

  test('the fixture request opens to its plaintext at its path', () async {
    final request = fx['request'] as Map<String, dynamic>;
    final node = request['node'] as Map<String, dynamic>;
    final plain = await cipher.open(
      node['_e2e'] as String,
      path: '$relayRoot/${request['path']}',
    );
    expect(jsonDecode(plain), request['plain']);
  });

  test('our sealed request opens, at its own path only', () async {
    final plain =
        (fx['request'] as Map<String, dynamic>)['plain']
            as Map<String, dynamic>;
    final body = plain['body'] as Map<String, dynamic>;
    final unit = await sealRequest(
      cipher,
      ClaudeRelayRequest(
        requestId: rid,
        slotMinute: body['client_slot_min'] as int,
        mode: ClaudeRelayMode.due,
        text: body['text'] as String,
        photoJpeg: Uint8List.fromList(
          base64.decode(body['photo_jpeg_b64'] as String),
        ),
      ),
      device: plain['dev'] as String,
      nowMs: plain['sent_at'] as int,
    );
    expect(unit.keys.toSet(), {'_e2e', 'created'});
    expect(unit['created'], {'.sv': 'timestamp'});
    final opened = jsonDecode(
      await cipher.open(
        unit['_e2e']! as String,
        path: '${requestNode(rid)}/req',
      ),
    );
    expect(opened, plain);
    await expectLater(
      cipher.open(unit['_e2e']! as String, path: '${requestNode(rid)}/result'),
      throwsA(isA<E2eDecryptError>()),
    );
  });

  test('the fixture logged result becomes a Claude entry', () async {
    final logged =
        (fx['results'] as Map<String, dynamic>)['logged']
            as Map<String, dynamic>;
    final event = await openResult(cipher, rid, logged['node']);
    final entry = (event as ClaudeRelayLogged).entry;
    final plain = logged['plain'] as Map<String, dynamic>;
    expect(entry.id, fx['entry_id']);
    expect(entry.desc, plain['desc']);
    expect(entry.kcal, plain['kcal']);
    expect(entry.proteinG, plain['protein_g']);
    expect(entry.slotMinute, plain['slot_min']);
    expect(entry.time, plain['time']);
    expect(entry.source, 'claude');
  });

  for (final name in ['error', 'expired']) {
    test('the fixture $name result fails with its code', () async {
      final res =
          (fx['results'] as Map<String, dynamic>)[name] as Map<String, dynamic>;
      final event = await openResult(cipher, rid, res['node']);
      expect(
        (event as ClaudeRelayFailed).reason,
        (res['plain'] as Map<String, dynamic>)['error_code'],
      );
    });
  }

  test('a result for another request does not open', () async {
    final logged =
        (fx['results'] as Map<String, dynamic>)['logged']
            as Map<String, dynamic>;
    final event = await openResult(
      cipher,
      '01JD5Z8K3M7Q2W9XH4TBN6VR0F',
      logged['node'],
    );
    expect(event, isA<ClaudeRelayFailed>());
  });

  test('a wrong key, a plain node and junk all fail closed', () async {
    final other = (await E2eKey.fromBytes(
      List.filled(32, 7),
    )).cipher(acceptPlaintext: false);
    final logged =
        (fx['results'] as Map<String, dynamic>)['logged']
            as Map<String, dynamic>;
    expect(
      await openResult(other, rid, logged['node']),
      isA<ClaudeRelayFailed>(),
    );
    expect(await openResult(cipher, rid, null), isA<ClaudeRelayFailed>());
    expect(
      await openResult(cipher, rid, {'ok': true}),
      isA<ClaudeRelayFailed>(),
    );
  });

  test('an entry id the phone did not derive is refused', () async {
    final sealed = await cipher.seal(
      jsonEncode({
        'ok': true,
        'status': 'logged',
        'id': rid,
        'entry_id': 'not-the-derived-id',
        'desc': 'x',
        'grams': 1,
        'kcal': 1,
        'protein_g': 1,
        'carbs_g': 1,
        'fat_g': 1,
        'slot_min': 480,
        'time': '2026-11-17T12:00:00+01:00',
      }),
      path: '${requestNode(rid)}/result',
    );
    final event = await openResult(cipher, rid, {'_e2e': sealed, 'at': 1});
    expect(event, isA<ClaudeRelayFailed>());
  });

  group('body cases', () {
    for (final c in (fx['body_cases'] as List).cast<Map<String, dynamic>>()) {
      test('${c['name']} is ${c['valid'] == true ? 'valid' : 'refused'}', () {
        final problem = relayBodyProblem(
          (c['body'] as Map<String, dynamic>).cast<String, Object?>(),
        );
        expect(problem == null, c['valid']);
      });
    }

    test('our own body for a text-only request is valid', () {
      final body = relayBody(
        const ClaudeRelayRequest(requestId: 'x', slotMinute: 720, text: ' a '),
      );
      expect(body, {'text': 'a', 'client_slot_min': 720, 'mode': 'normal'});
      expect(relayBodyProblem(body), isNull);
    });
  });
}
