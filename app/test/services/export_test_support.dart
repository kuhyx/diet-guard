// Shared fixtures for the export-key tests.

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/export_keyring.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/kuchnia_credential_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';

import 'body_test_support.dart';

/// The catering login the tests hide.
const testPassword = 'hunter2-PANEL-pw';

/// The catering account the tests hide.
const testMail = 'kuhy@example.pl';

/// An in-memory OS keystore; [broken] simulates it being unavailable.
class MemorySecrets {
  /// Stored secrets by key.
  final Map<String, String> data = {};

  /// When true every access throws.
  bool broken = false;

  /// A keyring over this keystore.
  ExportKeyring keyring() => ExportKeyring(
    read: (key) async => broken ? throw StateError('no keystore') : data[key],
    write: (key, value) async {
      if (broken) throw StateError('no keystore');
      data[key] = value;
    },
  );
}

/// Fresh in-memory stores; [kuchnia] seeds the catering login when given.
Future<void> bindFresh({(String, String)? kuchnia}) async {
  final store = MemoryDocStore();
  LogStorageService.resetForTesting(store: store);
  FoodBankService.resetForTesting(store: store);
  await AppSettingsService.initForTesting(store);
  await BudgetHistoryService.initForTesting(store);
  await MealScheduleService.initForTesting(store);
  await BodyService.initForTesting(store);
  await KuchniaCredentialService.initForTesting(MemoryDocStore());
  if (kuchnia != null) {
    await KuchniaCredentialService.instance.save(kuchnia.$1, kuchnia.$2);
  }
}

/// Writes one meal into the food log.
Future<void> seedMeal(String desc) async {
  final log = {
    '2026-10-01': [
      FoodEntry(
        id: 'id-$desc',
        time: '2026-10-01T08:05:00',
        desc: desc,
        grams: 100,
        kcal: 250,
        proteinG: 10,
        carbsG: 30,
        fatG: 8,
        source: 'manual',
        slotMinute: 480,
      ),
    ],
  };
  await LogStorageService.instance.writeLog(log);
  await FoodBankService.instance.rebuildAndPersist(log);
}

/// Every meal description in the local food log.
Future<List<String>> meals() async =>
    (await LogStorageService.instance.allEntriesNewestFirst())
        .map((e) => e.desc)
        .toList();
