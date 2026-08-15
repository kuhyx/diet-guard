/// Food-bank <-> crdt_sync.Record adapters, for both halves of the bank.
///
/// Split out of `sync_merge.dart` for file size; that file re-exports these
/// so existing importers keep working.
///
/// The derived bank's merge clock is the record's own `count`, not a wall
/// time: last-writer-wins therefore means *max-count-wins*, which is the
/// correct merge for a derived counter and is idempotent. The curated
/// (manual) bank is one record per normalized name, LWW by `editedAt`.
library;

import 'dart:convert';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/services/sync_device_id.dart';

/// Converts the log-derived food bank into a crdt_sync [Log].
///
/// The bank is *derived* -- both devices replay the same synced log and
/// compute the same records -- so this exists to make them agree
/// **immediately** rather than only after each has replayed.
///
/// The clock is the record's own `count`, not a wall time, so
/// last-writer-wins means *max-count-wins*: the device that has seen more of
/// the log has the higher count, and re-merging is idempotent because the
/// count does not move unless the log did. Mirrors
/// `_sync_merge.food_bank_to_log`.
Log foodBankToLog(Map<String, FoodBankRecord> bank) {
  final log = <String, Record>{};
  for (final mapEntry in bank.entries) {
    log[mapEntry.key] = Record(
      id: mapEntry.key,
      fields: {
        'body': (
          mapEntry.value.toJson(),
          Hlc.newTick(
            currentSyncDeviceId,
            wallTimeMsOverride: mapEntry.value.count.toInt(),
          ),
        ),
      },
    );
  }
  return log;
}

/// Converts a merged food-bank [Log] back into bank shape.
Map<String, FoodBankRecord> logToFoodBank(Log log) {
  final bank = <String, FoodBankRecord>{};
  for (final mapEntry in log.entries) {
    if (mapEntry.value.deleted) continue;
    final body = mapEntry.value.fields['body']?.$1;
    if (body is! Map) continue;
    bank[mapEntry.key] = FoodBankRecord.fromJson(
      Map<String, dynamic>.from(body.cast<String, dynamic>()),
    );
  }
  return bank;
}

/// Parses one device's pushed `food_bank.json` into a crdt_sync [Log].
Log parseRemoteFoodBank(String text) {
  final raw = jsonDecode(text);
  if (raw is! Map) {
    throw const FormatException(
      'top-level food-bank payload is not a JSON object',
    );
  }
  return raw.cast<String, dynamic>().map(
    (id, data) => MapEntry(id, Record.fromJson(data as Map<String, dynamic>)),
  );
}

/// Serializes a merged food-bank [Log] for push.
String encodeFoodBankForPush(Log log) => jsonEncode({
  for (final entry in log.entries) entry.key: entry.value.toJson(),
});

/// Converts the hand-curated food bank into a crdt_sync [Log].
///
/// One record per normalized food name, carrying the whole bank record as an
/// opaque `body` -- the same shape food-log entries use. Unlike an entry a
/// curated food is editable, so its [Hlc] comes from the record's own
/// `editedAt` stamp rather than a fixed birth time. Mirrors
/// `_sync_merge.manual_bank_to_log`.
Log manualBankToLog(Map<String, FoodBankRecord> bank) {
  final log = <String, Record>{};
  for (final mapEntry in bank.entries) {
    final wallTimeMs =
        DateTime.tryParse(
          mapEntry.value.editedAt ?? '',
        )?.toUtc().millisecondsSinceEpoch ??
        0;
    final body = Map<String, dynamic>.from(mapEntry.value.toJson())
      ..remove('t');
    log[mapEntry.key] = Record(
      id: mapEntry.key,
      fields: {
        'body': (
          body,
          Hlc.newTick(currentSyncDeviceId, wallTimeMsOverride: wallTimeMs),
        ),
      },
    );
  }
  return log;
}

/// Converts a merged curated-bank [Log] back into bank shape.
///
/// Each record's `editedAt` is reconstructed from its field [Hlc], so the
/// stored stamp and the clock the merge compared can never drift apart.
/// Mirrors `_sync_merge.log_to_manual_bank`.
Map<String, FoodBankRecord> logToManualBank(Log log) {
  final bank = <String, FoodBankRecord>{};
  for (final mapEntry in log.entries) {
    if (mapEntry.value.deleted) continue;
    final field = mapEntry.value.fields['body'];
    final body = field?.$1;
    if (body is! Map) continue;
    final json = Map<String, dynamic>.from(body.cast<String, dynamic>());
    final hlc = field?.$2;
    if (hlc != null) {
      json['t'] = DateTime.fromMillisecondsSinceEpoch(
        hlc.wallTimeMs,
        isUtc: true,
      ).toLocal().toIso8601String();
    }
    bank[mapEntry.key] = FoodBankRecord.fromJson(json);
  }
  return bank;
}

/// Parses one device's pushed curated-bank text into a crdt_sync [Log].
Log parseRemoteManualBank(String text) {
  final raw = jsonDecode(text);
  if (raw is! Map) {
    throw const FormatException(
      'top-level curated-bank payload is not a JSON object',
    );
  }
  return raw.cast<String, dynamic>().map(
    (id, data) => MapEntry(id, Record.fromJson(data as Map<String, dynamic>)),
  );
}

/// Serializes a merged curated-bank [Log] for push.
String encodeManualBankForPush(Log log) => jsonEncode({
  for (final entry in log.entries) entry.key: entry.value.toJson(),
});
