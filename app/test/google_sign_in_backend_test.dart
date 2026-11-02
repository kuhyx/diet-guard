import 'dart:io';

import 'package:diet_guard_app/services/google_sign_in_backend.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_account_token/google_account_token.dart'
    show kGoogleAccountTokenChannel;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(kGoogleAccountTokenChannel, null);
  });

  group('googleIdToken', () {
    test('returns the token the sign-in function yields', () async {
      // The injected path: proves the closure is what feeds crdt_sync, and
      // that no platform channel is touched to get there.
      expect(
        await googleIdToken(signInFn: () async => 'a-token'),
        'a-token',
      );
    });

    test('passes a null cancellation straight through', () async {
      // Dismissing the picker is an ordinary outcome, not an error: the
      // caller falls back to the password path.
      expect(await googleIdToken(signInFn: () async => null), isNull);
    });

    test('reports "not configured" when the client id is missing', () async {
      // A build without --dart-define=GOOGLE_SERVER_CLIENT_ID must fall back
      // rather than failing deep inside the plugin with an opaque message.
      expect(await googleIdToken(serverClientId: ''), isNull);
    });

    test('pins the uid the security rules expect', () {
      // If this ever drifts from database.rules.json, a Google sign-in would
      // be accepted here and then denied every read and write.
      expect(kSyncUid, 'OvA2REQyLIhAHOEjzwS1o877rgG3');
    });

    test('goes through the shared plugin channel by default', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      MethodCall? seen;
      messenger.setMockMethodCallHandler(kGoogleAccountTokenChannel, (call) {
        seen = call;
        return Future.value('jwt');
      });
      expect(await googleIdToken(), 'jwt');
      expect(seen?.method, 'idToken');
      expect(seen?.arguments, {'serverClientId': kServerClientId});
    });

    test('a cancelled chooser is null, not an error', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger.setMockMethodCallHandler(
        kGoogleAccountTokenChannel,
        (_) => Future.value(),
      );
      expect(await googleIdToken(), isNull);
    });
  });

  test('depends on the shared plugin, not google_sign_in', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('google_account_token-v0.1.0'));
    expect(pubspec, isNot(contains('google_sign_in:')));
  });
}
