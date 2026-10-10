/// Shared fixtures for the "Fill all with catering" tests.
library;

import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/services/document_store.dart';
import 'package:diet_guard_app/services/kuchnia_spread.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';

/// In-memory store, so these tests need no plugin channel or temp dir.
class MemoryStore implements DocumentStore {
  /// Stored documents by name.
  final Map<String, String> documents = {};

  @override
  Future<String?> read(String name) async => documents[name];

  @override
  Future<void> write(String name, String contents) async {
    documents[name] = contents;
  }
}

/// The default four-slot day.
const defaultSlots = [480, 720, 960, 1200];

/// A dish with the given [priority]; macros are distinct per priority.
KuchniaDish dish(String name, int priority, {double grams = 300}) =>
    KuchniaDish(
      name: name,
      kcal: 100.0 * priority,
      proteinG: 10.0 * priority,
      carbsG: 20.5,
      fatG: 5,
      grams: grams,
      priority: priority,
      slotLabel: 'Obiad',
    );

/// [count] dishes named `D1..Dn` in priority order.
List<KuchniaDish> dishes(int count) => [
  for (var i = 1; i <= count; i++) dish('D$i', i),
];

/// Pairs [dish] with [slot] directly, bypassing the spread.
SlottedDish at(KuchniaDish dish, int slot) =>
    SlottedDish(dish: dish, slot: slot);

/// Points the singleton at a fresh in-memory log and returns it.
LogStorageService freshStorage() {
  LogStorageService.resetForTesting(store: MemoryStore());
  return LogStorageService.instance;
}

/// `desc@slot` for every live entry logged today, in write order.
Future<List<String>> loggedToday(LogStorageService storage) async => [
  for (final e in await storage.todayEntries()) '${e.desc}@${e.slotMinute}',
];
