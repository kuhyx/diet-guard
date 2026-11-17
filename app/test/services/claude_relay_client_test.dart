/// The relay interface and its fake: the contract the screen depends on.
library;

import 'dart:async';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/services/claude_relay_client.dart';
import 'package:diet_guard_app/services/claude_relay_fake.dart';
import 'package:flutter_test/flutter_test.dart';

const _request = ClaudeRelayRequest(
  requestId: '01JD5Z8K3M7Q2W9XH4TBN6VR0E',
  slotMinute: 480,
  text: 'x',
);

void main() {
  test(
    'queued is not terminal: the same stream later delivers the meal',
    () async {
      final relay = FakeClaudeRelayClient();
      final events = <ClaudeRelayEvent>[];
      final done = Completer<void>();
      relay.send(_request).listen(events.add, onDone: done.complete);

      relay.emit(const ClaudeRelayQueued());
      await Future<void>.delayed(Duration.zero);
      expect(done.isCompleted, isFalse);

      final entry = FoodEntry(
        id: claudeEntryId(_request.requestId),
        time: 't',
        desc: 'x',
        grams: 1,
        kcal: 1,
        proteinG: 1,
        carbsG: 1,
        fatG: 1,
        source: 'claude',
      );
      relay.emit(ClaudeRelayLogged(entry));
      await done.future;
      expect(events.map((e) => e.runtimeType), [
        ClaudeRelayQueued,
        ClaudeRelayLogged,
      ]);
      expect(
        (events.last as ClaudeRelayLogged).entry.id,
        claudeEntryId(_request.requestId),
      );
    },
  );

  for (final event in [
    const ClaudeRelayLocked(),
    const ClaudeRelayFailed('boom'),
  ]) {
    test('${event.runtimeType} ends the stream', () async {
      final relay = FakeClaudeRelayClient();
      final done = Completer<void>();
      relay.send(_request).listen((_) {}, onDone: done.complete);
      relay.emit(event);
      await done.future;
    });
  }

  test('the fake records every request', () {
    final relay = FakeClaudeRelayClient()
      ..send(_request).listen((_) {})
      ..send(_request).listen((_) {});
    expect(relay.sent, hasLength(2));
  });

  test('the unwired client fails closed', () async {
    final events = await const UnconfiguredClaudeRelayClient()
        .send(_request)
        .toList();
    expect(events.single, isA<ClaudeRelayFailed>());
  });
}
