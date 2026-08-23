/// Fetches the day's catering dishes and banks them.
///
/// The Dart mirror of `diet_guard/_kuchnia_import.py`, and the module's single
/// fail-closed boundary: every [KuchniaError] is turned into a reason string
/// here, so no caller can be broken by a catering outage.
///
/// **Nothing is ever logged from here.** A delivered meal is not an eaten
/// meal: dishes land in the *curated* bank and the user still taps to log
/// each one. If the import logged automatically, the gate would satisfy its
/// own checkpoint from a delivery note, and the log would record what the
/// courier dropped off rather than what was eaten -- skipped, shared and
/// binned meals included.
///
/// Imports go **only** to the curated bank. The derived bank is rebuilt from
/// the log on every meal, so anything written there would vanish at the next
/// entry.
///
/// The idempotency guard is load-bearing and easy to get wrong.
/// `addManualEntry` restamps `editedAt` unconditionally and the sync merge
/// derives each record's clock from it -- so calling it for unchanged dishes
/// would republish the *entire* curated bank to every peer on every refresh.
/// [bankDishes] therefore compares the nutritional fields first and writes
/// only what actually differs.
library;

import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/kuchnia_client.dart';
import 'package:diet_guard_app/services/kuchnia_credential_service.dart';
import 'package:diet_guard_app/services/kuchnia_errors.dart';
import 'package:diet_guard_app/services/kuchnia_orders.dart';

/// The result of one refresh: the dishes, or why there are none.
class KuchniaRefresh {
  /// Creates a refresh result.
  const KuchniaRefresh({this.dishes = const [], this.reason});

  /// The day's dishes, empty on failure or when nothing was delivered.
  final List<KuchniaDish> dishes;

  /// Why the panel could not be read, or null on success.
  ///
  /// Callers surface this and carry on; it is never thrown.
  final String? reason;

  /// True when the fetch succeeded, whether or not anything was delivered.
  bool get ok => reason == null;
}

/// Returns the curated-bank record for [dish].
FoodBankRecord dishToRecord(KuchniaDish dish) => FoodBankRecord(
  desc: dish.name,
  kcal: dish.kcal,
  proteinG: dish.proteinG,
  carbsG: dish.carbsG,
  fatG: dish.fatG,
  grams: dish.grams,
  // The bank's count ranks foods by how often they were *eaten*, and a
  // delivered dish has not been eaten yet.
  count: 0,
);

/// True when [existing] already says exactly what [dish] says.
///
/// Compares the nutritional fields only. `editedAt` is excluded deliberately:
/// it is the edit stamp, not part of the record's meaning, and including it
/// would make every comparison differ -- which is the republish flood this
/// guard exists to prevent.
///
/// Numeric comparison, not string: `270 == 270.0` must be true here exactly as
/// it is in Python's `_matches`.
bool bankRecordMatches(FoodBankRecord existing, KuchniaDish dish) =>
    existing.desc == dish.name &&
    existing.kcal == dish.kcal &&
    existing.proteinG == dish.proteinG &&
    existing.carbsG == dish.carbsG &&
    existing.fatG == dish.fatG &&
    existing.grams == dish.grams;

/// Adds [dishes] to the curated bank, skipping ones already banked unchanged.
///
/// Returns how many records were actually written -- which is what the tests
/// assert on, because "the entry exists" passes while the guard misbehaves.
Future<int> bankDishes(List<KuchniaDish> dishes) async {
  final bank = await FoodBankService.instance.readManualBank();
  var written = 0;
  for (final dish in dishes) {
    final existing = bank[dish.bankKey];
    if (existing != null && bankRecordMatches(existing, dish)) continue;
    await FoodBankService.instance.addManualEntry(dishToRecord(dish));
    written++;
  }
  return written;
}

/// Fetches [day]'s dishes and banks them, never throwing.
///
/// Returns a reason string instead of raising, so a catering outage cannot
/// break the caller. On web it returns [kuchniaWebUnsupportedReason] without
/// touching the network: the panel sends no CORS headers, so the browser would
/// refuse the request anyway. That check comes first, before anything
/// platform-shaped runs.
Future<KuchniaRefresh> refreshDelivery(
  DateTime day, {
  KuchniaSession Function(String username, String password)? sessionFactory,
}) async {
  if (!kuchniaFetchSupported) {
    return const KuchniaRefresh(reason: kuchniaWebUnsupportedReason);
  }
  if (!KuchniaCredentialService.isConfigured) {
    return const KuchniaRefresh(
      reason: 'no catering credentials — add them in Settings',
    );
  }

  final session =
      (sessionFactory ??
          (username, password) =>
              KuchniaSession(username: username, password: password))(
        KuchniaCredentialService.username,
        KuchniaCredentialService.password,
      );
  List<KuchniaDish> dishes;
  try {
    dishes = await fetchDishes(session, day);
  } on KuchniaError catch (error) {
    return KuchniaRefresh(reason: error.message);
  } finally {
    session.close();
  }
  await bankDishes(dishes);
  return KuchniaRefresh(dishes: dishes);
}
