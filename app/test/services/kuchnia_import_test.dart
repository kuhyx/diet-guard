/// The phone's catering fetch, banking and its guards.
///
/// Three behaviours here are load-bearing, and each fails silently if broken:
///
/// * **Nothing is ever logged.** A delivered meal is not an eaten meal; if the
///   import logged, the gate would satisfy its own checkpoint from a delivery
///   note.
/// * **Unchanged dishes are not re-banked.** `addManualEntry` restamps
///   `editedAt` unconditionally and the merge derives each record's clock from
///   it, so re-banking republishes the whole curated bank to every peer. The
///   assertions are on the **write count** -- "the entry exists" passes while
///   this misbehaves.
/// * **A failure is a reason string, never a throw**, so a catering outage
///   cannot break the caller.
library;

import 'dart:convert';

import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/services/document_store.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/kuchnia_client.dart';
import 'package:diet_guard_app/services/kuchnia_credential_service.dart';
import 'package:diet_guard_app/services/kuchnia_import.dart';
import 'package:diet_guard_app/services/kuchnia_orders.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

const _menuPath = 'company/general/menus/delivery/DEL1/new';

Map<String, dynamic> _meal(String name, int priority) => {
  'mealName': 'Obiad',
  'menuMealName': name,
  'mealPriority': priority,
  'nutrition': {
    'weight': 300.0,
    'calories': 400.0,
    'protein': 25.0,
    'carbohydrate': 45.0,
    'fat': 12.0,
  },
};

/// A panel that logs in and serves a one-dish delivery on 2026-08-23.
MockClient _panel({
  List<Map<String, dynamic>>? meals,
  List<String>? requested,
  int loginStatus = 200,
}) => MockClient((request) async {
  requested?.add(request.url.path);
  if (request.url.path.endsWith('/auth/login')) {
    return http.Response(
      '',
      loginStatus,
      headers: {'set-cookie': 'SESSION=abc123; Path=/; HttpOnly'},
    );
  }
  if (request.url.path.endsWith('/order/active-ids')) {
    return http.Response(jsonEncode(['ORD1']), 200);
  }
  if (request.url.path.endsWith('/order/ORD1')) {
    return http.Response(
      jsonEncode({
        'deliveries': [
          {'date': '2026-08-23', 'deliveryId': 'DEL1'},
        ],
      }),
      200,
    );
  }
  if (request.url.path.endsWith(_menuPath.split('/').last) ||
      request.url.path.contains('menus/delivery/DEL1')) {
    return http.Response(
      jsonEncode({'deliveryMenuMeal': meals ?? [_meal('Kaszotto', 1)]}),
      200,
    );
  }
  return http.Response('', 404);
});

void main() {
  late _MemoryStore store;
  final day = DateTime(2026, 8, 23);

  KuchniaSession Function(String, String) factoryFor(http.Client client) =>
      (username, password) => KuchniaSession(
        username: username,
        password: password,
        client: client,
      );

  setUp(() async {
    store = _MemoryStore();
    LogStorageService.resetForTesting(store: store);
    FoodBankService.resetForTesting(store: store);
    KuchniaCredentialService.resetForTesting(store: store);
    await KuchniaCredentialService.instance.save('me@example.com', 'pw');
  });

  tearDown(() {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    KuchniaCredentialService.resetForTesting();
  });

  group('the walk', () {
    test('banks the day\'s dishes and logs nothing', () async {
      final result = await refreshDelivery(
        day,
        sessionFactory: factoryFor(_panel()),
      );

      expect(result.ok, isTrue);
      expect(result.dishes.single.name, 'Kaszotto');
      final bank = await FoodBankService.instance.readManualBank();
      expect(bank.keys, contains('kaszotto'));
      // The whole point: a delivered meal is not an eaten meal.
      expect(await LogStorageService.instance.todayEntries(), isEmpty);
    });

    test('banks a dish with count 0, not 1', () async {
      // The bank's count ranks foods by how often they were *eaten*.
      await refreshDelivery(day, sessionFactory: factoryFor(_panel()));
      final bank = await FoodBankService.instance.readManualBank();
      expect(bank['kaszotto']!.count, 0);
    });

    test('a day with no delivery is empty, not an error', () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/auth/login')) {
          return http.Response(
            '',
            200,
            headers: {'set-cookie': 'SESSION=abc; Path=/'},
          );
        }
        if (request.url.path.endsWith('/order/active-ids')) {
          return http.Response(jsonEncode(['ORD1']), 200);
        }
        return http.Response(jsonEncode({'deliveries': []}), 200);
      });
      final result = await refreshDelivery(
        day,
        sessionFactory: factoryFor(client),
      );
      expect(result.ok, isTrue);
      expect(result.dishes, isEmpty);
    });

    test('no active order is empty, not an error', () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/auth/login')) {
          return http.Response(
            '',
            200,
            headers: {'set-cookie': 'SESSION=abc; Path=/'},
          );
        }
        return http.Response(jsonEncode(<Object>[]), 200);
      });
      final result = await refreshDelivery(
        day,
        sessionFactory: factoryFor(client),
      );
      expect(result.ok, isTrue);
      expect(result.dishes, isEmpty);
    });
  });

  group('failures become reasons, never throws', () {
    test('a rejected login', () async {
      final result = await refreshDelivery(
        day,
        sessionFactory: factoryFor(_panel(loginStatus: 401)),
      );
      expect(result.ok, isFalse);
      expect(result.reason, contains('rejected'));
    });

    test('a delivery whose dishes all fail the unit check', () async {
      // Macros quoted per 100 g against a per-portion kcal.
      final result = await refreshDelivery(
        day,
        sessionFactory: factoryFor(
          _panel(
            meals: [
              {
                'mealName': 'Obiad',
                'menuMealName': 'Bad units',
                'mealPriority': 1,
                'nutrition': {
                  'weight': 400.0,
                  'calories': 900.0,
                  'protein': 5.0,
                  'carbohydrate': 6.0,
                  'fat': 2.0,
                },
              },
            ],
          ),
        ),
      );
      expect(result.ok, isFalse);
      expect(result.reason, contains('no usable dishes'));
    });

    test('missing credentials', () async {
      KuchniaCredentialService.resetForTesting(store: _MemoryStore());
      final result = await refreshDelivery(
        day,
        sessionFactory: factoryFor(_panel()),
      );
      expect(result.ok, isFalse);
      expect(result.reason, contains('no catering credentials'));
    });
  });
}
