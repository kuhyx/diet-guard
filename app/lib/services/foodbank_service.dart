/// Local food-bank (autocomplete index), mirroring diet_guard's
/// `_foodbank.py` -- but *derived*, not synced (see Milestone 3's decision
/// to avoid counter-merge logic entirely: every device rebuilds its own
/// bank by replaying its own post-merge log).
library;

import 'dart:convert';
import 'dart:io';

import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/models/food_suggestion.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/services/fuzzy.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Below this similarity ratio a non-substring candidate is dropped.
/// Mirrors `_foodbank._FUZZY_THRESHOLD`.
const double fuzzyThreshold = 0.6;

/// Default number of autocomplete suggestions to surface. Mirrors
/// `_foodbank.DEFAULT_SUGGESTIONS`.
const int defaultSuggestions = 8;

String _normalize(String description) => description.trim().toLowerCase();

Nutrition _recordToNutrition(FoodBankRecord record) => Nutrition(
  kcal: record.kcal,
  proteinG: record.proteinG,
  carbsG: record.carbsG,
  fatG: record.fatG,
  grams: record.grams,
  source: 'food bank',
);

String _displayName(FoodBankRecord record, String key) =>
    record.desc.trim().isEmpty ? key : record.desc;

/// Singleton service for the locally-rebuilt food bank.
class FoodBankService {
  FoodBankService._(this._file);

  static FoodBankService? _instance;

  /// Returns the initialized singleton; throws if [init] was not called.
  static FoodBankService get instance => _instance!;

  final File _file;

  /// Initializes the singleton, pointing at the app's documents directory.
  static Future<FoodBankService> init() async {
    if (_instance != null) return _instance!;
    final dir = await getApplicationDocumentsDirectory();
    final svc = FoodBankService._(File(p.join(dir.path, 'food_bank.json')));
    _instance = svc;
    return svc;
  }

  /// Resets the singleton so [init] can be called again in tests.
  @visibleForTesting
  static void resetForTesting({Directory? testDir}) {
    _instance = testDir == null
        ? null
        : FoodBankService._(File(p.join(testDir.path, 'food_bank.json')));
  }

  /// Reads the persisted bank (empty map on a missing/unparsable file).
  Future<Map<String, FoodBankRecord>> readBank() async {
    if (!_file.existsSync()) return {};
    String raw;
    try {
      raw = await _file.readAsString();
    } on FileSystemException {
      return {};
    }
    Object? data;
    try {
      data = jsonDecode(raw);
    } on FormatException {
      return {};
    }
    if (data is! Map) return {};
    final result = <String, FoodBankRecord>{};
    for (final mapEntry in data.entries) {
      final key = mapEntry.key;
      final value = mapEntry.value;
      if (key is String && value is Map) {
        result[key] = FoodBankRecord.fromJson(value.cast<String, dynamic>());
      }
    }
    return result;
  }

  /// Persists [bank] to disk, creating the parent directory if needed.
  Future<void> writeBank(Map<String, FoodBankRecord> bank) async {
    await _file.parent.create(recursive: true);
    final encoded = <String, Object?>{
      for (final mapEntry in bank.entries)
        mapEntry.key: mapEntry.value.toJson(),
    };
    await _file.writeAsString(jsonEncode(encoded));
  }

  /// Rebuilds the bank by replaying [log]'s entries in a fixed, device-
  /// independent order (by `time` then `id`), so any two devices that
  /// converge on the same merged log also converge on the same bank.
  ///
  /// Pure -- no I/O -- so it is independently unit-testable, mirroring
  /// `_foodbank.remember_food`/`remember_meal`'s upsert semantics: latest
  /// macros win per normalized name, `count` increments per occurrence.
  static Map<String, FoodBankRecord> rebuild(DayLog log) {
    final entries = log.values
        .expand((entries) => entries)
        .where((entry) => !entry.deleted)
        .toList()
      ..sort((a, b) {
        final byTime = a.time.compareTo(b.time);
        return byTime != 0 ? byTime : (a.id ?? '').compareTo(b.id ?? '');
      });
    final bank = <String, FoodBankRecord>{};
    for (final entry in entries) {
      final components = entry.components;
      if (components != null) {
        for (final component in components) {
          _upsert(
            bank,
            component.name,
            Nutrition(
              kcal: component.kcal,
              proteinG: component.proteinG,
              carbsG: component.carbsG,
              fatG: component.fatG,
              grams: component.grams,
              source: 'food bank',
            ),
            null,
          );
        }
        _upsert(
          bank,
          entry.desc,
          Nutrition(
            kcal: entry.kcal,
            proteinG: entry.proteinG,
            carbsG: entry.carbsG,
            fatG: entry.fatG,
            grams: entry.grams,
            source: entry.source,
          ),
          components.map((c) => c.name).toList(),
        );
      } else {
        _upsert(
          bank,
          entry.desc,
          Nutrition(
            kcal: entry.kcal,
            proteinG: entry.proteinG,
            carbsG: entry.carbsG,
            fatG: entry.fatG,
            grams: entry.grams,
            source: entry.source,
          ),
          null,
        );
      }
    }
    return bank;
  }

  static void _upsert(
    Map<String, FoodBankRecord> bank,
    String description,
    Nutrition nutrition,
    List<String>? components,
  ) {
    final key = _normalize(description);
    if (key.isEmpty) return;
    final previous = bank[key];
    final count = (previous?.count ?? 0) + 1;
    bank[key] = FoodBankRecord(
      desc: description.trim(),
      kcal: nutrition.kcal,
      proteinG: nutrition.proteinG,
      carbsG: nutrition.carbsG,
      fatG: nutrition.fatG,
      grams: nutrition.grams,
      count: count,
      components: components,
    );
  }

  /// Rebuilds the bank from [log] and persists it, returning the result.
  Future<Map<String, FoodBankRecord>> rebuildAndPersist(DayLog log) async {
    final bank = rebuild(log);
    await writeBank(bank);
    return bank;
  }

  /// Returns banked foods matching [query], best match first.
  ///
  /// An empty query returns the most-logged foods. Mirrors
  /// `_foodbank.search_foods`.
  Future<List<FoodSuggestion>> search(
    String query, {
    int limit = defaultSuggestions,
  }) async {
    final bank = await readBank();
    final normalized = _normalize(query);
    if (normalized.isEmpty) return _rankedAll(bank, limit);

    final scored = <(double score, double count, FoodSuggestion suggestion)>[];
    for (final mapEntry in bank.entries) {
      final score = matchScore(normalized, mapEntry.key);
      if (score < fuzzyThreshold) continue;
      final record = mapEntry.value;
      scored.add((
        score,
        record.count,
        FoodSuggestion(
          name: _displayName(record, mapEntry.key),
          nutrition: _recordToNutrition(record),
        ),
      ));
    }
    scored.sort((a, b) {
      final byScore = b.$1.compareTo(a.$1);
      return byScore != 0 ? byScore : b.$2.compareTo(a.$2);
    });
    return scored.take(limit).map((s) => s.$3).toList();
  }

  List<FoodSuggestion> _rankedAll(
    Map<String, FoodBankRecord> bank,
    int limit,
  ) {
    final ranked = bank.entries.toList()
      ..sort((a, b) => b.value.count.compareTo(a.value.count));
    return ranked
        .take(limit)
        .map(
          (mapEntry) => FoodSuggestion(
            name: _displayName(mapEntry.value, mapEntry.key),
            nutrition: _recordToNutrition(mapEntry.value),
          ),
        )
        .toList();
  }
}
