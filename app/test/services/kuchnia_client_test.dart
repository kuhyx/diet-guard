/// The catering login's error messages.
///
/// A 401 is a wrong password, and on the phone the only place to fix that is
/// Settings -- so only a 401 points there. Any other status is the panel's
/// problem; sending the user to re-type a correct password would mislead.
library;

import 'package:diet_guard_app/services/kuchnia_client.dart';
import 'package:diet_guard_app/services/kuchnia_errors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _settingsHint = 'check the password in Settings';

/// Logs in against a panel that answers the login with [status].
Future<KuchniaError> _loginError(int status) async {
  final session = KuchniaSession(
    username: 'me@example.com',
    password: 'pw',
    client: MockClient((_) async => http.Response('', status)),
  );
  try {
    await session.login();
  } on KuchniaError catch (error) {
    return error;
  }
  fail('a $status login must throw KuchniaError');
}

void main() {
  group('a rejected login', () {
    test('401 points the user at the password in Settings', () async {
      final error = await _loginError(401);
      expect(error.message, contains('HTTP 401'));
      expect(error.message, contains(_settingsHint));
    });

    test('500 is the panel\'s fault, not the password\'s', () async {
      final error = await _loginError(500);
      expect(error.message, contains('HTTP 500'));
      expect(error.message, isNot(contains(_settingsHint)));
    });
  });

  group('the CSRF handshake', () {
    // Since ~2026-10 the panel answers a login without `X-XSRF-TOKEN` with a
    // bare 403 that sets the XSRF-TOKEN cookie; a retry echoing it gets the
    // real answer. Without the retry every login failed with HTTP 403.
    const token = 'csrf-123';

    /// A panel that 403s until the token is echoed, then answers [then].
    KuchniaSession panel(
      http.Response Function() then,
      List<http.Request> seen,
    ) {
      return KuchniaSession(
        username: 'me@example.com',
        password: 'pw',
        client: MockClient((request) async {
          seen.add(request);
          final echoed =
              request.headers['X-XSRF-TOKEN'] == token &&
              (request.headers['Cookie'] ?? '').contains('XSRF-TOKEN=$token');
          if (!echoed) {
            return http.Response(
              '',
              403,
              headers: {'set-cookie': 'XSRF-TOKEN=$token; Path=/; Secure'},
            );
          }
          return then();
        }),
      );
    }

    test('a 403 is retried once echoing the token', () async {
      final seen = <http.Request>[];
      final session = panel(
        () => http.Response(
          '',
          200,
          headers: {'set-cookie': 'SESSION=sess-1; Path=/; HttpOnly'},
        ),
        seen,
      );
      await session.login();
      expect(seen, hasLength(2));
      expect(session.sessionCookie, 'sess-1');
    });

    test('a wrong password behind CSRF still points at Settings', () async {
      final session = panel(() => http.Response('Bad credentials', 401), []);
      await expectLater(
        session.login(),
        throwsA(
          isA<KuchniaError>().having(
            (e) => e.message,
            'message',
            contains(_settingsHint),
          ),
        ),
      );
    });

    test(
      'a 403 that survives the handshake is not a password problem',
      () async {
        final error = await _loginError(403);
        expect(error.message, contains('HTTP 403'));
        expect(error.message, contains('not a password problem'));
        expect(error.message, isNot(contains(_settingsHint)));
      },
    );
  });
}
