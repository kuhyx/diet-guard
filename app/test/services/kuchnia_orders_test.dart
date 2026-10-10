/// The catering walk's pure helpers: order/delivery selection and the cookie.
///
/// Split out of `kuchnia_import_test.dart` for the repo's 250-line cap. These
/// need no store, no credentials and no HTTP plumbing -- they are the parts of
/// the walk that are just parsing, and each one encodes a trap recovered from
/// the live panel rather than guessed from its JavaScript.
library;

import 'dart:convert';

import 'package:diet_guard_app/services/kuchnia_client.dart';
import 'package:diet_guard_app/services/kuchnia_orders.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A panel serving [orders] (id -> deliveries) as active ids, newest first,
/// and a one-dish menu for any delivery. Every GET path lands in [requested].
KuchniaSession _session(
  Map<String, List<Map<String, Object>>> orders,
  List<String> requested,
) {
  final client = MockClient((request) async {
    final path = request.url.path;
    requested.add(path);
    if (path.endsWith('/order/active-ids')) {
      return http.Response(jsonEncode(orders.keys.toList()), 200);
    }
    for (final id in orders.keys) {
      if (path.endsWith('/order/$id')) {
        return http.Response(jsonEncode({'deliveries': orders[id]}), 200);
      }
    }
    if (path.contains('/menus/delivery/')) {
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
  // A seeded cookie skips the login: these tests are about the order walk.
  return KuchniaSession(username: 'me', password: 'pw', client: client)
    ..sessionCookie = 'abc123';
}

void main() {
  group('the order walk', () {
    test('skips a cancelled delivery', () {
      // A `deleted` delivery still appears in the list.
      final order = {
        'deliveries': [
          {'date': '2026-08-23', 'deliveryId': 'GONE', 'deleted': true},
          {'date': '2026-08-23', 'deliveryId': 'REAL'},
        ],
      };
      expect(deliveryIdFor(order, '2026-08-23'), 'REAL');
    });

    test('a malformed order yields no delivery', () {
      expect(deliveryIdFor('nope', '2026-08-23'), isNull);
      expect(deliveryIdFor({'deliveries': 'nope'}, '2026-08-23'), isNull);
      expect(deliveryIdFor({}, '2026-08-23'), isNull);
    });

    test('a malformed active-ids payload yields no orders', () {
      expect(activeOrderIds('nope'), isEmpty);
      expect(activeOrderIds(null), isEmpty);
      expect(activeOrderIds(<Object>[]), isEmpty);
    });

    test('every active order id is returned, in the panel\'s order', () {
      expect(activeOrderIds(['FUTURE', 'CURRENT']), ['FUTURE', 'CURRENT']);
    });

    test('formats the day the way the panel keys deliveries', () {
      expect(isoDay(DateTime(2026, 8, 3)), '2026-08-03');
      expect(isoDay(DateTime(2026, 12, 31)), '2026-12-31');
    });
  });

  group('fetchDishes walks every active order', () {
    final day = DateTime(2026, 10, 10);

    test(
      'finds today in the second order when the first is a renewal',
      () async {
        // The panel lists ids newest first: on 2026-10-10 a renewal starting
        // 10-24 came first and today's delivery sat in the running order.
        final requested = <String>[];
        final session = _session({
          'FUTURE': [
            {'date': '2026-10-24', 'deliveryId': 'DEL_FUTURE'},
          ],
          'CURRENT': [
            {'date': '2026-10-10', 'deliveryId': 'DEL_TODAY'},
          ],
        }, requested);

        final dishes = await fetchDishes(session, day);

        expect(dishes.single.name, 'Kaszotto');
        expect(
          requested,
          contains(endsWith('/menus/delivery/DEL_TODAY/new')),
          reason: 'the menu must be keyed by the current order\'s delivery',
        );
        expect(requested, isNot(contains(contains('DEL_FUTURE'))));
      },
    );

    test('is empty when no active order has the day', () async {
      final requested = <String>[];
      final session = _session({
        'FUTURE': [
          {'date': '2026-10-24', 'deliveryId': 'DEL_FUTURE'},
        ],
        'CURRENT': [
          {'date': '2026-10-09', 'deliveryId': 'DEL_YESTERDAY'},
          {'date': '2026-10-10', 'deliveryId': 'GONE', 'deleted': true},
        ],
      }, requested);

      expect(await fetchDishes(session, day), isEmpty);
      // Both orders were read, and no menu was asked for.
      expect(requested, contains(endsWith('/order/FUTURE')));
      expect(requested, contains(endsWith('/order/CURRENT')));
      expect(requested, isNot(contains(contains('/menus/'))));
    });
  });

  group('the session cookie', () {
    test('is read out of a comma-joined set-cookie header', () {
      // `Response.headers` folds duplicate set-cookie values into one string.
      expect(
        sessionCookieFrom('SESSION=abc123; Path=/, OTHER=def; Path=/'),
        'abc123',
      );
      expect(
        sessionCookieFrom('OTHER=def; Path=/, SESSION=abc123; HttpOnly'),
        'abc123',
      );
    });

    test('is null when the panel sets no session cookie', () {
      expect(sessionCookieFrom(null), isNull);
      expect(sessionCookieFrom(''), isNull);
      expect(sessionCookieFrom('OTHER=def; Path=/'), isNull);
      expect(sessionCookieFrom('SESSION=; Path=/'), isNull);
    });
  });
}
