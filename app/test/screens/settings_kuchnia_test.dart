/// The catering credential section of the settings screen.
///
/// The behaviour that needs pinning is the platform split, because it is the
/// one thing a reader would plausibly "simplify" the wrong way: the credential
/// **fields** show everywhere (the desktop app is where a password is most
/// likely to be typed, and it syncs from there to the phone), while the
/// **fetch button** is Android-only, because the panel sends no CORS headers
/// and a browser cannot call it at all.
///
/// The section paints no text: controls are found by the spoken label their
/// icon carries, outcomes by the [StatusCue] kind they show.
library;

import 'dart:async';

import 'package:diet_guard_app/screens/settings_kuchnia.dart';
import 'package:diet_guard_app/services/document_store.dart';
import 'package:diet_guard_app/services/kuchnia_credential_service.dart';
import 'package:diet_guard_app/ui/cues.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../label_finders.dart';

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

Widget _host({
  required bool canFetch,
  Future<FetchOutcome> Function()? onFetch,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: KuchniaSettingsSection(canFetch: canFetch, onFetch: onFetch),
    ),
  ),
);

const _fetchLabel = "Fetch today's delivery";

/// The fetch button: the [IconButton] holding the delivery icon (or, while a
/// fetch runs, the spinner that replaces it).
Finder _fetchButton() => find.ancestor(
  of: find.byWidgetPredicate(
    (w) =>
        w is CircularProgressIndicator ||
        (w is Icon && w.semanticLabel == _fetchLabel),
  ),
  matching: find.byType(IconButton),
);

void main() {
  setUp(() => KuchniaCredentialService.resetForTesting(store: _MemoryStore()));
  tearDown(KuchniaCredentialService.resetForTesting);

  testWidgets('shows both credential fields on every platform', (tester) async {
    await tester.pumpWidget(_host(canFetch: false));
    expect(fieldByLabel('Panel e-mail'), findsOneWidget);
    expect(fieldByLabel('Panel password'), findsOneWidget);
  });

  testWidgets('the fetch button works only where it can', (tester) async {
    await tester.pumpWidget(_host(canFetch: true));
    expect(tester.widget<IconButton>(_fetchButton()).onPressed, isNotNull);

    await tester.pumpWidget(_host(canFetch: false));
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(_fetchButton()).onPressed,
      isNull,
      reason:
          'a browser user sees the button greyed out instead of vanishing; '
          'entering the login here still helps their phone',
    );
  });

  testWidgets('saving persists the credential', (tester) async {
    await tester.pumpWidget(_host(canFetch: true));
    await tester.enterText(find.byType(TextField).first, 'me@example.com');
    await tester.enterText(find.byType(TextField).last, 'hunter2');
    await tester.tap(controlByLabel('Save login'));
    await tester.pumpAndSettle();

    expect(KuchniaCredentialService.username, 'me@example.com');
    expect(KuchniaCredentialService.password, 'hunter2');
    expect(cueOfKind(CueKind.ok), findsOneWidget);
  });

  testWidgets('the password is obscured until revealed', (tester) async {
    await tester.pumpWidget(_host(canFetch: true));
    TextField passwordField() =>
        tester.widget<TextField>(find.byType(TextField).last);
    expect(passwordField().obscureText, isTrue);

    await tester.tap(controlByLabel('Show password'));
    await tester.pumpAndSettle();
    expect(passwordField().obscureText, isFalse);
  });

  testWidgets('a fetch shows its result as a cue and a count', (tester) async {
    await tester.pumpWidget(
      _host(
        canFetch: true,
        onFetch: () async =>
            const FetchOutcome(CueKind.ok, '3 dishes added', count: 3),
      ),
    );
    await tester.tap(controlByLabel(_fetchLabel));
    await tester.pumpAndSettle();
    expect(cueOfKind(CueKind.ok), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('a failed fetch shows an error cue, not a crash', (tester) async {
    await tester.pumpWidget(
      _host(
        canFetch: true,
        onFetch: () async =>
            const FetchOutcome(CueKind.error, 'catering login rejected'),
      ),
    );
    await tester.tap(controlByLabel(_fetchLabel));
    await tester.pumpAndSettle();
    expect(cueLabelled('catering login rejected'), findsOneWidget);
    expect(cueOfKind(CueKind.error), findsOneWidget);
  });

  testWidgets('the fetch button is disabled while a fetch is in flight', (
    tester,
  ) async {
    // Otherwise an impatient double-tap pays a second login plus three
    // requests against a third party.
    final gate = Completer<FetchOutcome>();
    await tester.pumpWidget(_host(canFetch: true, onFetch: () => gate.future));

    await tester.tap(controlByLabel(_fetchLabel));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<IconButton>(_fetchButton()).onPressed, isNull);

    gate.complete(const FetchOutcome(CueKind.ok, 'done'));
    await tester.pumpAndSettle();
  });
}
