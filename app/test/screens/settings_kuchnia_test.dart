/// The catering credential section of the settings screen.
///
/// The behaviour that needs pinning is the platform split, because it is the
/// one thing a reader would plausibly "simplify" the wrong way: the credential
/// **fields** show everywhere (the desktop app is where a password is most
/// likely to be typed, and it syncs from there to the phone), while the
/// **fetch button** is Android-only, because the panel sends no CORS headers
/// and a browser cannot call it at all.
library;

import 'dart:async';

import 'package:diet_guard_app/screens/settings_kuchnia.dart';
import 'package:diet_guard_app/services/document_store.dart';
import 'package:diet_guard_app/services/kuchnia_credential_service.dart';
import 'package:flutter/material.dart';
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

Widget _host({required bool canFetch, Future<String> Function()? onFetch}) =>
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: KuchniaSettingsSection(canFetch: canFetch, onFetch: onFetch),
        ),
      ),
    );

void main() {
  setUp(() => KuchniaCredentialService.resetForTesting(store: _MemoryStore()));
  tearDown(KuchniaCredentialService.resetForTesting);

  testWidgets('shows both credential fields on every platform', (tester) async {
    await tester.pumpWidget(_host(canFetch: false));
    expect(find.text('Panel e-mail'), findsOneWidget);
    expect(find.text('Panel password'), findsOneWidget);
  });

  testWidgets('offers the fetch button only where it can work', (tester) async {
    await tester.pumpWidget(_host(canFetch: true));
    expect(find.text("Fetch today's delivery"), findsOneWidget);

    await tester.pumpWidget(_host(canFetch: false));
    await tester.pumpAndSettle();
    expect(find.text("Fetch today's delivery"), findsNothing);
  });

  testWidgets('explains the missing button rather than hiding it silently', (
    tester,
  ) async {
    await tester.pumpWidget(_host(canFetch: false));
    expect(
      find.textContaining('Android only'),
      findsOneWidget,
      reason: 'a browser user needs to know why there is no fetch button, and '
          'that entering the login here still helps their phone',
    );
  });

  testWidgets('saving persists the credential', (tester) async {
    await tester.pumpWidget(_host(canFetch: true));
    await tester.enterText(find.byType(TextField).first, 'me@example.com');
    await tester.enterText(find.byType(TextField).last, 'hunter2');
    await tester.tap(find.text('Save login'));
    await tester.pumpAndSettle();

    expect(KuchniaCredentialService.username, 'me@example.com');
    expect(KuchniaCredentialService.password, 'hunter2');
    expect(find.textContaining('Saved'), findsOneWidget);
  });

  testWidgets('the password is obscured until revealed', (tester) async {
    await tester.pumpWidget(_host(canFetch: true));
    TextField passwordField() =>
        tester.widget<TextField>(find.byType(TextField).last);
    expect(passwordField().obscureText, isTrue);

    await tester.tap(find.byTooltip('Show password'));
    await tester.pumpAndSettle();
    expect(passwordField().obscureText, isFalse);
  });

  testWidgets('a fetch shows its result', (tester) async {
    await tester.pumpWidget(
      _host(canFetch: true, onFetch: () async => '3 dishes added'),
    );
    await tester.tap(find.text("Fetch today's delivery"));
    await tester.pumpAndSettle();
    expect(find.text('3 dishes added'), findsOneWidget);
  });

  testWidgets('a failed fetch shows the reason, not a crash', (tester) async {
    await tester.pumpWidget(
      _host(canFetch: true, onFetch: () async => 'catering login rejected'),
    );
    await tester.tap(find.text("Fetch today's delivery"));
    await tester.pumpAndSettle();
    expect(find.text('catering login rejected'), findsOneWidget);
  });

  testWidgets('the fetch button is disabled while a fetch is in flight', (
    tester,
  ) async {
    // Otherwise an impatient double-tap pays a second login plus three
    // requests against a third party.
    final gate = Completer<String>();
    await tester.pumpWidget(_host(canFetch: true, onFetch: () => gate.future));

    await tester.tap(find.text("Fetch today's delivery"));
    await tester.pump();
    expect(find.text('Fetching…'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(button.onPressed, isNull);

    gate.complete('done');
    await tester.pumpAndSettle();
  });
}
