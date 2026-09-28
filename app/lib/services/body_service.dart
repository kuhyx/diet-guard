/// Persistence for the Body document: profile, weight log, PC workouts.
///
/// A singleton over the platform [DocumentStore], shaped like
/// `MealScheduleService`. Every setter stamps the edited part with "now", so
/// a manual edit outranks an ingested phone weigh-in of the same day in the
/// last-writer-wins merge (`sync_merge_body.dart`). Nothing here touches the
/// budget -- the Body screen is informational only.
///
/// Mirrors the storage half of `diet_guard/_body_store.py`.
library;

import 'dart:convert';

import 'package:diet_guard_app/models/body_document.dart';
import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/services/activity_kcal.dart';
import 'package:diet_guard_app/services/body_calc.dart';
import 'package:diet_guard_app/services/document_store.dart';
import 'package:diet_guard_app/services/document_store_factory.dart';
import 'package:flutter/foundation.dart';

/// Singleton owning the `body.json` document.
class BodyService {
  BodyService._(this._store);

  /// Document name this service owns.
  static const documentName = 'body.json';

  static BodyService? _instance;

  /// Returns the initialized singleton; throws if [init] was not called.
  static BodyService get instance => _instance!;

  /// True once [init] (or a test initialiser) has run.
  static bool get isInitialized => _instance != null;

  final DocumentStore _store;
  BodyDocument _doc = const BodyDocument();

  /// The whole document, for the sync layer.
  BodyDocument get document => _doc;

  /// Initialises the singleton against the platform document store.
  static Future<BodyService> init() async {
    if (_instance != null) return _instance!;
    // coverage:ignore-start
    final svc = BodyService._(await openDocumentStore());
    // coverage:ignore-end
    await svc._load();
    _instance = svc;
    return svc;
  }

  /// Initialises from [store], for tests.
  @visibleForTesting
  static Future<BodyService> initForTesting(DocumentStore store) async {
    final svc = BodyService._(store);
    await svc._load();
    _instance = svc;
    return svc;
  }

  /// Drops the singleton, or -- given a [store] -- seeds an empty one over
  /// it so a later [init] reuses it instead of reaching the platform store.
  @visibleForTesting
  static void resetForTesting({DocumentStore? store}) {
    _instance = store == null ? null : BodyService._(store);
  }

  Future<void> _load() async {
    final raw = await _store.read(documentName);
    if (raw == null) return;
    try {
      _doc = BodyDocument.fromJson(jsonDecode(raw));
    } on FormatException {
      // A corrupt document reads as empty, like the other services.
    }
  }

  Future<void> _write(BodyDocument doc) async {
    _doc = doc;
    await _store.write(documentName, jsonEncode(doc.toJson()));
  }

  /// Birth date as `YYYY-MM-DD`, or null.
  String? get birth => _string(profileBirth);

  /// Height in cm, or null.
  double? get heightCm {
    final value = _doc.profile[profileHeight]?.value;
    return value is num ? value.toDouble() : null;
  }

  /// `m` / `f`, or null.
  String? get sex {
    final value = _string(profileSex);
    return value == 'm' || value == 'f' ? value : null;
  }

  /// Whether birth date, height and sex are all set -- the Body screen then
  /// moves the profile card to the bottom.
  bool get profileComplete =>
      DateTime.tryParse(birth ?? '') != null && heightCm != null && sex != null;

  String? _string(String name) {
    final value = _doc.profile[name]?.value;
    return value is String && value.isNotEmpty ? value : null;
  }

  /// Sets the given profile fields, each stamped now; others are untouched.
  Future<void> setProfile({
    String? birth,
    double? heightCm,
    String? sex,
    DateTime? now,
  }) => setProfileFields({
    profileBirth: ?birth,
    profileHeight: ?heightCm,
    profileSex: ?sex,
  }, now: now);

  /// Sets raw profile [fields], each stamped now; others keep their stamps.
  Future<void> setProfileFields(
    Map<String, Object?> fields, {
    DateTime? now,
  }) async {
    if (fields.isEmpty) return;
    final t = isoLocalSeconds(now ?? DateTime.now());
    final profile = Map<String, Stamped>.from(_doc.profile);
    fields.forEach((name, value) => profile[name] = Stamped(value, t));
    await _write(_doc.copyWith(profile: profile));
  }

  /// A raw profile value, or null.
  Object? profileValue(String name) => _doc.profile[name]?.value;

  /// Records [kg] for [day] (`YYYY-MM-DD`), stamped now.
  Future<void> setWeight(String day, double kg, {DateTime? now}) =>
      _putWeight(day, kg, now);

  /// Deletes [day]'s weight (a tombstone, so the delete syncs).
  Future<void> deleteWeight(String day, {DateTime? now}) =>
      _putWeight(day, null, now);

  Future<void> _putWeight(String day, double? kg, DateTime? now) async {
    final weights = Map<String, WeightEntry>.from(_doc.weights);
    weights[day] = WeightEntry(
      kg: kg,
      src: 'manual',
      t: isoLocalSeconds(now ?? DateTime.now()),
    );
    await _write(_doc.copyWith(weights: weights));
  }

  /// Records [pct] body fat for [day], stamped now (one decimal, half-up).
  Future<void> setBodyFat(String day, double pct, {DateTime? now}) =>
      _putBodyFat(day, halfUp(pct, 1), now);

  /// Deletes [day]'s body fat (a tombstone, so the delete syncs).
  Future<void> deleteBodyFat(String day, {DateTime? now}) =>
      _putBodyFat(day, null, now);

  Future<void> _putBodyFat(String day, double? pct, DateTime? now) async {
    final bodyFat = Map<String, BodyFatEntry>.from(_doc.bodyFat);
    bodyFat[day] = BodyFatEntry(
      pct: pct,
      t: isoLocalSeconds(now ?? DateTime.now()),
    );
    await _write(_doc.copyWith(bodyFat: bodyFat));
  }

  /// Non-deleted body fat readings, oldest first, as `(YYYY-MM-DD, %)`.
  List<(String, double)> get bodyFatSeries =>
      _series(_doc.bodyFat.map((day, entry) => MapEntry(day, entry.pct)));

  /// The newest non-deleted body fat %, or null.
  (String, double)? get latestBodyFat {
    final series = bodyFatSeries;
    return series.isEmpty ? null : series.last;
  }

  /// Applies ingested weigh-ins: each replaces its day only when the local
  /// entry is missing or stamped **older**. Returns whether anything changed.
  Future<bool> applyCandidates(Map<String, WeightEntry> candidates) async {
    final weights = Map<String, WeightEntry>.from(_doc.weights);
    var changed = false;
    candidates.forEach((day, candidate) {
      final local = weights[day];
      if (local == null || stampMillis(local.t) < stampMillis(candidate.t)) {
        weights[day] = candidate;
        changed = true;
      }
    });
    if (changed) await _write(_doc.copyWith(weights: weights));
    return changed;
  }

  /// Replaces the document with a sync merge result.
  Future<void> applyMerged(BodyDocument merged) => _write(merged);

  /// Non-deleted weights, oldest first, as `(YYYY-MM-DD, kg)`.
  List<(String, double)> get weightSeries =>
      _series(_doc.weights.map((day, entry) => MapEntry(day, entry.kg)));

  static List<(String, double)> _series(Map<String, double?> byDay) {
    final days = byDay.keys.toList()..sort();
    return [
      for (final day in days)
        if (byDay[day] case final value?) (day, value),
    ];
  }

  /// The newest non-deleted weight, or null.
  (String, double)? get latestWeight {
    final series = weightSeries;
    return series.isEmpty ? null : series.last;
  }

  /// Workouts the PC published, parsed; null when it never published any.
  List<Session>? get sessions {
    final activity = _doc.activity;
    if (activity == null) return null;
    return [for (final raw in activity.sessions) ?Session.fromWire(raw)];
  }
}
