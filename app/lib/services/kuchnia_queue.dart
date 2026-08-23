/// The day's delivered dishes, offered to the log form one at a time.
///
/// **A delivered meal is not an eaten meal.** This queue only ever *prefills*
/// the form; the user still taps to log each dish. Nothing here writes a log
/// entry, and nothing here may start doing so -- the gate would then satisfy
/// its own checkpoint from a delivery note, and the log would record what the
/// courier dropped off rather than what was eaten.
///
/// Two things are load-bearing:
///
/// * **The queue survives a submit.** After a dish is logged the next one is
///   already in the form, so one tap walks the whole delivery. On the PC this
///   regressed once into a dead letter -- every dish after the first stayed
///   queued behind another click, and because the refresh there is unguarded
///   that meant a fresh login-plus-three-requests *per dish*.
/// * **The automatic refresh is guarded** by a device-local "already fetched
///   today" marker, mirroring Python's `refresh_delivery_once`. Without it
///   every logged meal would pay a login plus three requests against a third
///   party. Only a *clean* fetch records the day, so an outage is retried.
///   The settings button deliberately does **not** go through this: an
///   explicit ask always goes and looks, matching `diet-guard kuchnia`.
library;

import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/services/document_store.dart';
import 'package:diet_guard_app/services/kuchnia_import.dart';
import 'package:diet_guard_app/services/kuchnia_orders.dart' show isoDay;
import 'package:flutter/foundation.dart';

/// Holds today's delivered dishes and hands them out in the caterer's order.
class KuchniaQueueService {
  KuchniaQueueService._(this._store);

  /// Document holding the last fetched day, one ISO date.
  ///
  /// Device-local on purpose: this is a rate limit, not shared state. Syncing
  /// it would let one device's fetch suppress another's.
  static const documentName = 'kuchnia_last_import.json';

  static KuchniaQueueService? _instance;

  /// Returns the initialized singleton; throws if [init] was not called.
  static KuchniaQueueService get instance => _instance!;

  /// True once initialised, so callers can skip work in widget tests.
  static bool get isInitialized => _instance != null;

  final DocumentStore _store;
  final List<KuchniaDish> _pending = [];
  String _lastImportDay = '';

  /// The dishes not yet logged, in the caterer's own meal order.
  static List<KuchniaDish> get pending =>
      List.unmodifiable(_instance?._pending ?? const []);

  /// The next dish to offer, or null when the queue is empty.
  static KuchniaDish? get next =>
      (_instance?._pending.isEmpty ?? true) ? null : _instance!._pending.first;

  /// How many dishes are still waiting to be logged.
  static int get remaining => _instance?._pending.length ?? 0;

  /// Initialises from [store], for tests and for [init].
  @visibleForTesting
  static Future<KuchniaQueueService> initForTesting(DocumentStore store) async {
    final service = KuchniaQueueService._(store);
    await service._load();
    _instance = service;
    return service;
  }

  /// Resets the singleton so [initForTesting] can run again.
  @visibleForTesting
  static void resetForTesting() => _instance = null;

  Future<void> _load() async {
    final raw = await _store.read(documentName);
    if (raw != null) _lastImportDay = raw.trim();
  }

  /// True when [day]'s delivery has already been fetched on this device.
  bool alreadyFetched(DateTime day) => _lastImportDay == isoDay(day);

  /// Records that [day]'s delivery was fetched cleanly.
  ///
  /// Best-effort: this is a rate limit, not state anyone depends on. Failing
  /// to write it costs one extra fetch, which is strictly better than failing
  /// an import that already succeeded.
  Future<void> recordFetched(DateTime day) async {
    _lastImportDay = isoDay(day);
    try {
      await _store.write(documentName, _lastImportDay);
    } on Exception {
      // Ignore: an unrecorded fetch just means we look again.
    }
  }

  /// Replaces the queue with [dishes], dropping any already logged today.
  void offer(List<KuchniaDish> dishes, {Set<String> alreadyLogged = const {}}) {
    _pending
      ..clear()
      ..addAll(
        dishes.where((dish) => !alreadyLogged.contains(dish.bankKey)),
      );
  }

  /// Removes [dish] from the queue once it has actually been logged.
  void markLogged(KuchniaDish dish) =>
      _pending.removeWhere((queued) => queued.bankKey == dish.bankKey);

  /// Empties the queue, e.g. when the day rolls over.
  void clear() => _pending.clear();

  /// Fetches [day]'s delivery unless it has already been fetched today.
  ///
  /// Returns an empty, successful result when the day was already fetched --
  /// "nothing new", not an error. This is the entry point every *automatic*
  /// trigger uses; the settings button calls [refreshDelivery] directly.
  static Future<KuchniaRefresh> refreshOnce(DateTime day) async {
    final service = _instance;
    if (service == null) return const KuchniaRefresh();
    if (service.alreadyFetched(day)) return const KuchniaRefresh();
    final result = await refreshDelivery(day);
    if (result.ok) await service.recordFetched(day);
    return result;
  }
}
