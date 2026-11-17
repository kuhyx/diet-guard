/// A controllable [ClaudeRelayClient] for tests and the unwired app.
library;

import 'dart:async';

import 'package:diet_guard_app/services/claude_relay_client.dart';

/// Records every request and lets the test emit the events by hand.
///
/// [emit] pushes to the most recent send's stream; a terminal event closes it,
/// as a real client's would.
class FakeClaudeRelayClient implements ClaudeRelayClient {
  /// Every request sent, oldest first.
  final List<ClaudeRelayRequest> sent = [];

  /// Events replayed on each send before the stream waits for [emit].
  final List<ClaudeRelayEvent> script = [];

  StreamController<ClaudeRelayEvent>? _open;

  @override
  Stream<ClaudeRelayEvent> send(ClaudeRelayRequest request) {
    sent.add(request);
    final controller = StreamController<ClaudeRelayEvent>();
    _open = controller;
    script.forEach(emit);
    return controller.stream;
  }

  /// Delivers [event] to the open stream; a terminal one closes it.
  void emit(ClaudeRelayEvent event) {
    final controller = _open;
    if (controller == null || controller.isClosed) return;
    controller.add(event);
    if (event is! ClaudeRelayQueued) unawaited(controller.close());
  }
}
