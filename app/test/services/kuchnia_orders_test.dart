/// The catering walk's pure helpers: order/delivery selection and the cookie.
///
/// Split out of `kuchnia_import_test.dart` for the repo's 250-line cap. These
/// need no store, no credentials and no HTTP plumbing -- they are the parts of
/// the walk that are just parsing, and each one encodes a trap recovered from
/// the live panel rather than guessed from its JavaScript.
library;

import 'package:diet_guard_app/services/kuchnia_client.dart';
import 'package:diet_guard_app/services/kuchnia_orders.dart';
import 'package:flutter_test/flutter_test.dart';

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

    test('a malformed active-ids payload yields no order', () {
      expect(activeOrderId('nope'), isNull);
      expect(activeOrderId(<Object>[]), isNull);
      expect(activeOrderId(['ORD1']), 'ORD1');
    });

    test('formats the day the way the panel keys deliveries', () {
      expect(isoDay(DateTime(2026, 8, 3)), '2026-08-03');
      expect(isoDay(DateTime(2026, 12, 31)), '2026-12-31');
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
