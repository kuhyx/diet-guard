/// What `refreshOnce` records as "already fetched today".
///
/// Split out of `kuchnia_queue_test.dart` for the repo's 250-line cap. Only a
/// fetch that found dishes may record the day. An empty "no delivery" answer
/// is exactly what a walk that missed the delivery looks like (the 2026-10-10
/// renewal-first `active-ids` bug), and recording it would suppress every
/// retry until midnight. The assertions count **fetches**, not results.
///
/// `refreshOnce` has no session seam, so the panel is injected through
/// `http.runWithClient`: `KuchniaSession` falls back to `http.Client()`, which
/// resolves to the zone's client.
library;

import 'dart:convert';

import 'package:diet_guard_app/services/document_store.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/kuchnia_credential_service.dart';
import 'package:diet_guard_app/services/kuchnia_import.dart';
import 'package:diet_guard_app/services/kuchnia_queue.dart';
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

/// A panel whose one order has [deliveries]; [fetches] counts the walks.
MockClient _panel(List<Map<String, Object>> deliveries, List<int> fetches) =>
    MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/auth/login')) {
        return http.Response(
          '',
          200,
          headers: {'set-cookie': 'SESSION=abc123; Path=/'},
        );
      }
      if (path.endsWith('/order/active-ids')) {
        fetches[0]++;
        return http.Response(jsonEncode(['ORD1']), 200);
      }
      if (path.endsWith('/order/ORD1')) {
        return http.Response(jsonEncode({'deliveries': deliveries}), 200);
      }
      if (path.contains('/menus/delivery/DEL1')) {
        return http.Response(
          jsonEncode({
            'deliveryMenuMeal': [
              {
                'mealName': 'Obiad',
                'menuMealName': 'Kaszotto',
                'mealPriority': 1,
                'nutrition': {
                  'weight': 300.0,
                  'calories': 400.0,
                  'protein': 25.0,
                  'carbohydrate': 45.0,
                  'fat': 12.0,
                },
              },
            ],
          }),
          200,
        );
      }
      return http.Response('', 404);
    });

void main() {
  late _MemoryStore store;
  final today = DateTime(2026, 8, 23);

  Future<KuchniaRefresh> refreshAgainst(http.Client panel) => http
      .runWithClient(() => KuchniaQueueService.refreshOnce(today), () => panel);

  setUp(() async {
    store = _MemoryStore();
    FoodBankService.resetForTesting(store: store);
    KuchniaCredentialService.resetForTesting(store: store);
    await KuchniaCredentialService.instance.save('me@example.com', 'pw');
    await KuchniaQueueService.initForTesting(store);
  });

  tearDown(() {
    KuchniaQueueService.resetForTesting();
    FoodBankService.resetForTesting();
    KuchniaCredentialService.resetForTesting();
  });

  test('an empty successful fetch does not record the day', () async {
    final fetches = [0];
    final panel = _panel(const [], fetches);

    final first = await refreshAgainst(panel);
    expect(first.ok, isTrue);
    expect(first.dishes, isEmpty);
    expect(KuchniaQueueService.instance.alreadyFetched(today), isFalse);

    await refreshAgainst(panel);
    expect(fetches[0], 2, reason: 'an empty answer must not suppress a retry');
  });

  test('a fetch that found dishes records the day', () async {
    final fetches = [0];
    final panel = _panel(const [
      {'date': '2026-08-23', 'deliveryId': 'DEL1'},
    ], fetches);

    final first = await refreshAgainst(panel);
    expect(first.dishes.single.name, 'Kaszotto');
    expect(KuchniaQueueService.instance.alreadyFetched(today), isTrue);

    await refreshAgainst(panel);
    expect(fetches[0], 1, reason: 'the guard must still stop a second walk');
  });
}
