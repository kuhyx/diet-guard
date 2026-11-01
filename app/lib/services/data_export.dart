/// User-owned export and merge-only import of every synced document.
///
/// Import is `mergeLogs` plus the sync tick's own write-back, so it never
/// deletes and a repeat is a no-op. The catering login (a password) travels
/// only as an AEAD-sealed `kuchnia` section; see `data_export_kuchnia.dart`.
library;

import 'dart:convert';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/services/data_export_kuchnia.dart';
import 'package:diet_guard_app/services/export_keyring.dart';
import 'package:diet_guard_app/services/export_keyring_default.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/sync_budget_local.dart';
import 'package:diet_guard_app/services/sync_merge.dart';
import 'package:diet_guard_app/services/sync_merge_body.dart';

/// The `format` marker an export carries.
const exportFormat = 'diet_guard_export';

/// The newest export layout this build reads and writes.
const exportVersion = 1;

class _Document {
  const _Document(this.key, this.readLocal, this.apply);

  final String key;
  final Future<Log> Function() readLocal;
  final Future<void> Function(Log merged) apply;
}

Future<void> _applyFoodLog(Log merged) async {
  final log = logToDayLog(merged);
  await LogStorageService.instance.writeLog(log);
  await FoodBankService.instance.rebuildAndPersist(log);
}

Future<Log> _readBody() async =>
    BodyService.isInitialized ? bodyToLog(BodyService.instance.document) : {};

Future<void> _applyBody(Log merged) async {
  if (merged.isEmpty || !BodyService.isInitialized) return;
  await BodyService.instance.applyMerged(logToBody(merged));
}

/// Food log first: applying it rebuilds the derived bank merged next.
final List<_Document> _documents = [
  _Document(
    'food_log',
    () async => dayLogToLog(await LogStorageService.instance.readLog()),
    _applyFoodLog,
  ),
  _Document(
    'food_bank',
    () async => foodBankToLog(await FoodBankService.instance.readBank()),
    (merged) => FoodBankService.instance.writeBank(logToFoodBank(merged)),
  ),
  _Document(
    'food_bank_manual',
    () async =>
        manualBankToLog(await FoodBankService.instance.readManualBank()),
    (merged) =>
        FoodBankService.instance.applyMergedManualBank(logToManualBank(merged)),
  ),
  _Document('budget', () async => localBudgetLog(), applyBudgetLog),
  const _Document('body', _readBody, _applyBody),
];

Map<String, Object?> _encodeLog(Log log) => {
  for (final entry in log.entries) entry.key: entry.value.toJson(),
};

Log _decodeLog(String key, Object? payload) {
  if (payload is! Map) throw FormatException('"$key" is not an object');
  try {
    return {
      for (final entry in payload.entries)
        entry.key as String: Record.fromJson(
          (entry.value as Map).cast<String, dynamic>(),
        ),
    };
  } on Object catch (error) {
    throw FormatException('"$key" has a malformed record: $error');
  }
}

/// Returns every synced document as one pretty-printed JSON export.
///
/// The encrypted login section uses the newest key of [keyring] (default: the
/// OS-keystore ring).
Future<String> exportAllData({DateTime? now, ExportKeyring? keyring}) async {
  final documents = <String, Object?>{
    for (final doc in _documents) doc.key: _encodeLog(await doc.readLocal()),
  };
  return const JsonEncoder.withIndent('  ').convert({
    'format': exportFormat,
    'version': exportVersion,
    'exportedAt': (now ?? DateTime.now()).toIso8601String(),
    'documents': documents,
    ...await kuchniaExportEntries(keyring ?? defaultKeyring()),
  });
}

/// Merges an [exportAllData] payload into the local store.
///
/// Parses every document before writing any, so a bad file changes nothing.
/// Throws [FormatException] when [text] is not a diet_guard export. A sealed
/// login that cannot be opened (unknown key id even after [pullKeys], or
/// tampered data) is skipped after the rest merged, then reported as
/// [KuchniaImportException]. An existing local login is kept.
Future<void> importAllData(
  String text, {
  ExportKeyring? keyring,
  Future<void> Function() pullKeys = pullExportKeys,
}) async {
  final Object? raw;
  try {
    raw = jsonDecode(text);
  } on FormatException {
    throw const FormatException('not valid JSON');
  }
  if (raw is! Map || raw['format'] != exportFormat) {
    throw const FormatException('not a diet_guard export');
  }
  final version = raw['version'];
  final documents = raw['documents'];
  if (version is! int || version > exportVersion || documents is! Map) {
    throw const FormatException('unsupported diet_guard export');
  }
  final incoming = <_Document, Log>{
    for (final doc in _documents)
      if (documents[doc.key] != null)
        doc: _decodeLog(doc.key, documents[doc.key]),
  };
  final before = {for (final doc in incoming.keys) doc: await doc.readLocal()};
  for (final MapEntry(key: doc, value: log) in incoming.entries) {
    final local = mergeLogs(before[doc]!, await doc.readLocal());
    await doc.apply(mergeLogs(local, log));
  }
  await importKuchnia(raw, keyring ?? defaultKeyring(), pullKeys);
}
