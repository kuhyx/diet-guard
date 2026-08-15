// The curated ("manual") half of the food bank, plus ranked search across
// both halves.
//
// Split out of `foodbank_service.dart` for the repo's 250-line cap. It is a
// `part` rather than a separate library because these methods reach the
// service's private members (`_readBank`, `_writeBank`, `_normalize`,
// `_recordToNutrition`), which a `library`-private name makes invisible
// across a file boundary -- and widening them to public just to split a file
// would leak internals the rest of the app has no business calling.

part of 'foodbank_service.dart';

/// The curated bank and cross-bank search, split out for the file cap.
extension FoodBankManual on FoodBankService {
  // ---------------------------------------------------------------------------
  // Manual bank (food items added directly without logging them as eaten)
  // ---------------------------------------------------------------------------

  Future<Map<String, FoodBankRecord>> _readManualBank() =>
      _readBank(FoodBankService.manualDocumentName);

  Future<void> _writeManualBank(Map<String, FoodBankRecord> bank) =>
      _writeBank(FoodBankService.manualDocumentName, bank);

  /// Adds or updates [record] in the manually-curated bank without logging it
  /// as eaten. A repeated call with the same normalized name overwrites the
  /// previous entry.
  Future<void> addManualEntry(FoodBankRecord record) async {
    final bank = await _readManualBank();
    bank[_normalize(record.desc)] = FoodBankRecord(
      desc: record.desc,
      kcal: record.kcal,
      proteinG: record.proteinG,
      carbsG: record.carbsG,
      fatG: record.fatG,
      grams: record.grams,
      count: record.count,
      components: record.components,
      // Stamped here, not by callers: this is what the cross-device merge
      // orders by, so it must be set on every write without exception.
      editedAt: DateTime.now().toIso8601String(),
    );
    await _writeManualBank(bank);
  }

  /// Returns the hand-curated bank, for the sync layer.
  Future<Map<String, FoodBankRecord>> readManualBank() => _readManualBank();

  /// Replaces the hand-curated bank with a merge result from the sync layer.
  Future<void> applyMergedManualBank(Map<String, FoodBankRecord> bank) =>
      _writeManualBank(bank);

  /// All known food records: log-derived entries merged with manually-added
  /// ones, sorted by count descending.
  ///
  /// Log-derived records (from [readBank]) take precedence over manual records
  /// with the same normalized name.
  Future<List<FoodBankRecord>> mergedEntries() async {
    final logBank = await readBank();
    final manualBank = await _readManualBank();
    final merged = <String, FoodBankRecord>{...manualBank, ...logBank};
    return merged.values.toList()..sort((a, b) => b.count.compareTo(a.count));
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  /// Returns banked foods matching [query], best match first.
  ///
  /// An empty query returns the most-logged foods. Mirrors
  /// `_foodbank.search_foods`. Searches both log-derived and manually-added
  /// entries; log-derived entries win on name collision.
  Future<List<FoodSuggestion>> search(
    String query, {
    int limit = defaultSuggestions,
  }) async {
    final logBank = await readBank();
    final manualBank = await _readManualBank();
    final bank = <String, FoodBankRecord>{...manualBank, ...logBank};
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
