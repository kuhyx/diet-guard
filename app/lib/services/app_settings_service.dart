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
/// never call [init].
class AppSettingsService {
  AppSettingsService._(this._file);

  static AppSettingsService? _instance;

  /// Returns the initialized singleton; throws if [init] was not called.
  static AppSettingsService get instance => _instance!;

  final File _file;
  int _dailyKcalGoal = 2200;

  /// Returns the configured daily kcal goal, or 2200 when uninitialised.
  static int get dailyKcalGoal => _instance?._dailyKcalGoal ?? 2200;

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
    } on Exception {
      // Ignore parse errors and keep default.
    }
  }

  /// Updates the in-memory value and persists [goal] to disk.
  Future<void> saveDailyKcalGoal(int goal) async {
    _dailyKcalGoal = goal;
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode({'daily_kcal_goal': goal}));
  }
}
