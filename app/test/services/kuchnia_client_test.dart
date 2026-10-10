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
}
