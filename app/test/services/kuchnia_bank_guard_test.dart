/// The catering bank's idempotency guard.
///
/// Split out of `kuchnia_import_test.dart` for the repo's 250-line cap.
///
/// `addManualEntry` restamps `editedAt` unconditionally and the sync merge
/// derives each record's clock from it, so re-banking a dish that has not
/// changed republishes the **whole** curated bank to every peer on every
/// refresh. These assertions are on the **write count** for that reason:
/// "the entry exists" passes happily while the guard is broken.
library;

import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/services/document_store.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/kuchnia_import.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory store, so these tests need no plugin channel.
class _MemoryStore implements DocumentStore {
  final Map<String, String> documents = {};

  @override
  Future<String?> read(String name) async => documents[name];

  @override
  Future<void> write(String name, String contents) async {
    documents[name] = contents;
  }
}

const _dish = KuchniaDish(
  name: 'Kaszotto',
  kcal: 400,
  proteinG: 25,
  carbsG: 45,
  fatG: 12,
  grams: 300,
  priority: 1,
  slotLabel: 'Obiad',
);

void main() {
  setUp(() => FoodBankService.resetForTesting(store: _MemoryStore()));
  tearDown(FoodBankService.resetForTesting);

  group('the idempotency guard', () {
    test('re-banking an unchanged dish writes nothing', () async {
      // `addManualEntry` restamps `editedAt` unconditionally, so a second write
      // republishes the whole curated bank to every peer.
      expect(await bankDishes([_dish]), 1);
      expect(
        await bankDishes([_dish]),
        0,
        reason: 'an unchanged dish was re-banked, which restamps every record '
            'and republishes the whole curated bank',
      );
    });

    test('a changed macro is re-banked', () async {
      expect(await bankDishes([_dish]), 1);
      const changed = KuchniaDish(
        name: 'Kaszotto',
        kcal: 450,
        proteinG: 25,
        carbsG: 45,
        fatG: 12,
        grams: 300,
        priority: 1,
        slotLabel: 'Obiad',
      );
      expect(await bankDishes([changed]), 1);
    });

    test('an int-vs-double macro counts as unchanged', () async {
      // Python's `_matches` is lenient here (`270 == 270.0`), and a string
      // comparison instead would rewrite the bank on every refresh.
      const existing = FoodBankRecord(
        desc: 'Kaszotto',
        kcal: 400,
        proteinG: 25,
        carbsG: 45,
        fatG: 12,
        grams: 300,
        count: 0,
      );
      expect(bankRecordMatches(existing, _dish), isTrue);
    });
  });
}
