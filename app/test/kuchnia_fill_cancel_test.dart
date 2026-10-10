/// Cancelling "Fill all" while its first-tap fetch is still in flight.
///
/// Its own file because `kuchnia_fill_flow_test.dart` is at the 250-line cap.
/// The UI disables Cancel while busy, so this guards the flow itself: a
/// dismissed proposal must not arm when the late fetch lands.
library;

import 'dart:async';

import 'package:diet_guard_app/services/kuchnia_fill_flow.dart';
import 'package:diet_guard_app/services/kuchnia_import.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'kuchnia_fill_support.dart';

void main() {
  tearDown(LogStorageService.resetForTesting);

  test('cancel during the fetch leaves nothing armed', () async {
    final gate = Completer<void>();
    final flow = FillAllFlow(
      fetch: (_) async {
        await gate.future;
        return KuchniaRefresh(dishes: dishes(4));
      },
      now: () => DateTime(2026, 8, 23, 10),
      slots: () => defaultSlots,
      occupiedSlots: () async => <int>{},
      storage: freshStorage(),
    );

    final pending = flow.tap();
    flow.cancel();
    gate.complete();

    expect(await pending, isNull);
    expect(flow.armedCount, 0);
  });
}
