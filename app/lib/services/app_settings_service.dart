/// User-adjustable app settings persisted locally as JSON.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Singleton storing lightweight settings such as the daily kcal goal.
///
/// The static [dailyKcalGoal] getter returns the default (2200) when the
/// singleton has not been initialised — safe to read in widget tests that
/// never call [init]. [dailyKcalGoalUpdatedAt] is null until the goal has
/// been explicitly set (by the user or a sync merge) at least once on this
/// device -- that null is what tells the sync layer this device has
/// nothing of its own to contribute yet, rather than silently syncing the
/// unset default.
class AppSettingsService {
  AppSettingsService._(this._file);

  static AppSettingsService? _instance;

  /// Returns the initialized singleton; throws if [init] was not called.
  static AppSettingsService get instance => _instance!;

  final File _file;
  int _dailyKcalGoal = 2200;
  DateTime? _dailyKcalGoalUpdatedAt;
  String? _rewardLabel;
  String? _rewardUrl;

  /// Returns the configured daily kcal goal, or 2200 when uninitialised.
  static int get dailyKcalGoal => _instance?._dailyKcalGoal ?? 2200;

  /// Returns when the goal was last set on this device, or null if never.
  static DateTime? get dailyKcalGoalUpdatedAt =>
      _instance?._dailyKcalGoalUpdatedAt;

  /// Returns the configured temptation-bundling reward label, or null.
  ///
  /// Device-local only -- no `updatedAt`/sync merge wiring, unlike the kcal
  /// goal. Adding a sync-ready timestamp without real merge logic in
  /// `sync_merge.dart`/`sync_service.dart` would imply cross-device behavior
  /// that doesn't exist yet.
  static String? get rewardLabel => _instance?._rewardLabel;

  /// Returns the configured temptation-bundling reward URL, or null.
  static String? get rewardUrl => _instance?._rewardUrl;

  /// Initialises the singleton, pointing at the app's documents directory.
  static Future<AppSettingsService> init() async {
    if (_instance != null) return _instance!;
    final dir = await getApplicationDocumentsDirectory();
    final svc = AppSettingsService._(
      File(p.join(dir.path, 'app_settings.json')),
    );
    await svc._load();
    _instance = svc;
    return svc;
  }

  /// Resets the singleton so [init] can be called again in tests.
  ///
  /// When [testDir] is given, reads/writes go there instead of the real
  /// documents directory.
  @visibleForTesting
  static void resetForTesting({Directory? testDir}) {
    _instance = testDir == null
        ? null
        : AppSettingsService._(
            File(p.join(testDir.path, 'app_settings.json')),
          );
  }

  /// Initialises from [testDir], calling [_load], for use in unit tests.
  ///
  /// Bypasses [getApplicationDocumentsDirectory] so tests don't need platform
  /// channels.
  @visibleForTesting
  static Future<AppSettingsService> initForTesting(Directory testDir) async {
    final svc = AppSettingsService._(
      File(p.join(testDir.path, 'app_settings.json')),
    );
    await svc._load();
    _instance = svc;
    return svc;
  }

  Future<void> _load() async {
    if (!_file.existsSync()) return;
    try {
      final data = jsonDecode(await _file.readAsString());
      if (data is Map && data['daily_kcal_goal'] is int) {
        _dailyKcalGoal = data['daily_kcal_goal'] as int;
      }
      if (data is Map && data['daily_kcal_goal_updated_at'] is String) {
        _dailyKcalGoalUpdatedAt = DateTime.tryParse(
          data['daily_kcal_goal_updated_at'] as String,
        );
      }
      if (data is Map && data['reward_label'] is String) {
        _rewardLabel = data['reward_label'] as String;
      }
      if (data is Map && data['reward_url'] is String) {
        _rewardUrl = data['reward_url'] as String;
      }
    } on Exception {
      // Ignore parse errors and keep defaults.
    }
  }

  /// Updates the in-memory value and persists [goal] to disk, stamping the
  /// edit with the current time -- the timestamp a sync merge compares
  /// against another device's edit to resolve last-writer-wins.
  Future<void> saveDailyKcalGoal(int goal) => _persist(goal, DateTime.now());

  /// Applies a synced budget value without stamping a fresh edit time.
  ///
  /// Used only by the sync layer to write back a merge's winning value: it
  /// persists [updatedAt] verbatim (the winning side's real edit time), not
  /// "now", so re-syncing an unchanged value stays idempotent instead of
  /// making this device's copy look newer than it actually is on every
  /// tick.
  Future<void> applySyncedBudget(int goal, {DateTime? updatedAt}) =>
      _persist(goal, updatedAt);

  /// Updates and persists the temptation-bundling reward shown after a
  /// one-tap "repeat last meal" log. Pass `null` for either field to clear
  /// it.
  Future<void> saveReward({String? label, String? url}) async {
    _rewardLabel = label;
    _rewardUrl = url;
    await _writeToDisk();
  }

  Future<void> _persist(int goal, DateTime? updatedAt) async {
    _dailyKcalGoal = goal;
    _dailyKcalGoalUpdatedAt = updatedAt;
    await _writeToDisk();
  }

  /// Writes the full current in-memory state to disk -- the single write
  /// path every setter funnels through, so no two methods can race on
  /// independently overwriting the same JSON file.
  Future<void> _writeToDisk() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      jsonEncode({
        'daily_kcal_goal': _dailyKcalGoal,
        'daily_kcal_goal_updated_at': _dailyKcalGoalUpdatedAt
            ?.toIso8601String(),
        'reward_label': _rewardLabel,
        'reward_url': _rewardUrl,
      }),
    );
  }
}
