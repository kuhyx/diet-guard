/// The relay's wire format: sealing a request, opening a result.
///
/// Mirrors `docs/DOCS-claude-relay.md` sections 1 to 3 and is gated by
/// `tests/fixtures/claude_relay_contract.json`. A unit is
/// `{"_e2e": <blob>, <clear siblings>}`; the blob is crdt_sync's [E2eCipher]
/// over compact JSON with the unit's full path as AAD, so a blob copied to
/// another path does not open. Both the request (photo included) and the
/// result are sealed: no food text or image is ever in clear.
library;

import 'dart:convert';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/services/claude_relay_client.dart';

/// The relay's root `R`; its header is the existing `diet-guard-sync/e2e`.
const relayRoot = 'diet-guard-sync/claude-e2e';

/// Largest base64 photo the worker accepts, in characters.
const relayPhotoB64Max = 600000;

/// Longest description the worker accepts, in characters after trimming.
const relayTextMax = 2000;

/// The node of request [rid].
String requestNode(String rid) => '$relayRoot/requests/$rid';

/// Returns why [body] breaks the contract, or null when it is valid.
///
/// The same rules the worker enforces (`bad_request`), checked here first so a
/// request that can only fail never leaves the phone.
String? relayBodyProblem(Map<String, Object?> body) {
  final text = body['text'];
  final photo = body['photo_jpeg_b64'];
  if (text == null && photo == null) return 'nothing to estimate';
  if (text != null) {
    if (text is! String) return 'text is not a string';
    final length = text.trim().runes.length;
    if (length < 1 || length > relayTextMax) return 'text length';
  }
  if (photo != null) {
    if (photo is! String || photo.length > relayPhotoB64Max) {
      return 'photo size';
    }
    try {
      final bytes = base64.decode(photo);
      if (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
        return 'photo is not a jpeg';
      }
    } on FormatException {
      return 'photo is not base64';
    }
  }
  final slot = body['client_slot_min'];
  if (slot is! int || slot < 0 || slot > 1439) return 'slot';
  if (body['mode'] != 'due' && body['mode'] != 'normal') return 'mode';
  return null;
}

/// The request's `body` object.
Map<String, Object?> relayBody(ClaudeRelayRequest request) => {
  if (request.text.trim().isNotEmpty) 'text': request.text.trim(),
  if (request.photoJpeg != null)
    'photo_jpeg_b64': base64.encode(request.photoJpeg!),
  'client_slot_min': request.slotMinute,
  'mode': request.mode.name,
};

/// The sealed `req` unit for [request], ready to PUT.
///
/// `created` is the server's clock, not the phone's: it drives the worker's
/// 24 h expiry, and a phone clock can be wrong.
Future<Map<String, Object?>> sealRequest(
  E2eCipher cipher,
  ClaudeRelayRequest request, {
  required String device,
  required int nowMs,
}) async {
  final plain = {
    'kind': 'meal',
    'dev': device,
    'sent_at': nowMs,
    'body': relayBody(request),
  };
  return {
    '_e2e': await cipher.seal(
      jsonEncode(plain),
      path: '${requestNode(request.requestId)}/req',
    ),
    'created': {'.sv': 'timestamp'},
  };
}

/// Opens the `result` unit of [rid] into the event the screen shows.
///
/// Fail closed: anything that is not exactly a logged meal for this request,
/// with the entry id the phone derived itself, is a [ClaudeRelayFailed].
Future<ClaudeRelayEvent> openResult(
  E2eCipher cipher,
  String rid,
  Object? node,
) async {
  try {
    if (node is! Map || node['_e2e'] is! String) {
      return const ClaudeRelayFailed('result is not a sealed unit');
    }
    final plain =
        jsonDecode(
              await cipher.open(
                node['_e2e'] as String,
                path: '${requestNode(rid)}/result',
              ),
            )
            as Map<String, dynamic>;
    if (plain['id'] != rid) return const ClaudeRelayFailed('result id');
    if (plain['ok'] != true || plain['status'] != 'logged') {
      return ClaudeRelayFailed('${plain['error_code'] ?? 'error'}');
    }
    if (plain['entry_id'] != claudeEntryId(rid)) {
      return const ClaudeRelayFailed('entry id mismatch');
    }
    return ClaudeRelayLogged(
      FoodEntry(
        id: plain['entry_id'] as String,
        time: plain['time'] as String,
        desc: plain['desc'] as String,
        grams: (plain['grams'] as num).toDouble(),
        kcal: (plain['kcal'] as num).toDouble(),
        proteinG: (plain['protein_g'] as num).toDouble(),
        carbsG: (plain['carbs_g'] as num).toDouble(),
        fatG: (plain['fat_g'] as num).toDouble(),
        source: 'claude',
        slotMinute: plain['slot_min'] as int?,
      ),
    );
  } on E2eDecryptError {
    return const ClaudeRelayFailed('result did not open');
  } on Object {
    // A wrong type or a missing field in a result is a bad answer, not a
    // crash; the meal is not shown as logged.
    return const ClaudeRelayFailed('result is malformed');
  }
}
