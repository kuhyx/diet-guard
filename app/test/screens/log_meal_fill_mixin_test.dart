/// "Fill all with catering" as the log form drives it.
///
/// `kuchnia_fill_flow_test.dart` proves the flow writes nothing until the
/// second tap. This covers what the *screen* must do around it: publish once
/// for the whole batch (and never after the first tap), drop the filled
/// dishes from the delivery queue, and not leave a just-logged dish
/// prefilled in the form where a second submit would duplicate it.
///
/// Driven through a minimal host, like `log_meal_kuchnia_mixin_test.dart`:
/// the real `LogMealScreen` fans out into sync and notifications and does not
/// pump to quiescence in a widget test.
library;

import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/screens/log_meal_fill_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_kuchnia_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_sync_mixin.dart';
import 'package:diet_guard_app/services/kuchnia_fill.dart';
import 'package:diet_guard_app/services/kuchnia_fill_flow.dart';
import 'package:diet_guard_app/services/kuchnia_import.dart';
import 'package:diet_guard_app/services/kuchnia_queue.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/widgets/macro_input_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../kuchnia_fill_support.dart';

class _Host extends StatefulWidget {
  const _Host(this.storage, this.delivery);

  final LogStorageService storage;
  final List<KuchniaDish> delivery;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host>
    with
        WidgetsBindingObserver,
        LogMealSyncMixin<_Host>,
        LogMealKuchniaMixin<_Host>,
        LogMealFillMixin<_Host> {
  final TextEditingController desc = TextEditingController();
  final MacroControllers macros = MacroControllers();
  int publishes = 0;
  String status = '';

  @override
  int? selectedSlot;

  @override
  http.Client? get syncHttpClient => null;

  @override
  TextEditingController get descController => desc;

  @override
  MacroControllers get macroControllers => macros;

  @override
  void initState() {
    super.initState();
    fillFlow = FillAllFlow(
      fetch: (_) async => KuchniaRefresh(dishes: widget.delivery),
      slots: () => defaultSlots,
      storage: widget.storage,
    );
  }

  @override
  void showFillStatus(String message) => setState(() => status = message);

  /// Counted instead of run: the real one starts a network sync.
  @override
  Future<DayLog> publishAfterLog() {
    publishes++;
    return widget.storage.readLog();
  }

  @override
  Widget build(BuildContext context) =>
      Text(status, textDirection: TextDirection.ltr);
}

void main() {
  late LogStorageService storage;
  late _HostState host;
  final delivery = dishes(4);

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: _Host(storage, delivery)));
    host = tester.state(find.byType(_Host));
    // Mirrors the screen: the delivery is queued and the first dish prefilled.
    KuchniaQueueService.instance.offer(delivery);
    host.prefillNextDish();
  }

  setUp(() async {
    storage = freshStorage();
    await KuchniaQueueService.initForTesting(MemoryStore());
  });

  tearDown(() {
    KuchniaQueueService.resetForTesting();
    LogStorageService.resetForTesting();
  });

  testWidgets('the first tap only proposes: no write, no publish', (t) async {
    await pumpHost(t);

    await t.runAsync(host.onFillAll);

    expect(host.status, startsWith('Will log 4'));
    expect(await t.runAsync(storage.todayEntries), isEmpty);
    expect(host.publishes, 0);
    expect(KuchniaQueueService.remaining, 4);
    expect(host.desc.text, 'D1');
  });

  testWidgets('confirm logs the batch, publishes once, empties the queue', (
    t,
  ) async {
    await pumpHost(t);

    await t.runAsync(() async {
      await host.onFillAll();
      await host.onFillAll();
    });

    expect(host.status, 'Logged 4 catering dishes.');
    expect(await t.runAsync(() => loggedToday(storage)), hasLength(4));
    expect(host.publishes, 1, reason: 'one publish per batch, not per dish');
    expect(KuchniaQueueService.remaining, 0);
    expect(host.loggedSlots, {8, 12, 16, 20});
    expect(host.desc.text, isEmpty, reason: 'D1 was logged by the fill');
  });

  testWidgets('a dish the fill skipped stays queued and prefilled', (t) async {
    await pumpHost(t);
    await t.runAsync(() async {
      await storage.logMeal(
        'own breakfast',
        dishNutrition(dish('own', 1)),
        slot: 8,
      );
      await host.onFillAll();
      await host.onFillAll();
    });

    // D1's slot was taken, so only D2..D4 landed and D1 is still on offer.
    expect(host.status, 'Logged 3 catering dishes.');
    expect(KuchniaQueueService.remaining, 1);
    expect(host.desc.text, 'D1');
  });

  testWidgets('cancel says so and writes nothing', (t) async {
    await pumpHost(t);
    await t.runAsync(host.onFillAll);

    host.onFillCancel();
    await t.pump();

    expect(host.status, contains('cancelled'));
    expect(host.fillFlow.armedCount, 0);
    expect(await t.runAsync(storage.todayEntries), isEmpty);
    expect(host.publishes, 0);
  });

  testWidgets('a failure mid-fill publishes what landed and says so', (
    t,
  ) async {
    await pumpHost(t);
    host.fillFlow = FillAllFlow(
      fetch: (_) async => KuchniaRefresh(dishes: delivery),
      slots: () => defaultSlots,
      occupiedSlots: () async => throw Exception('storage unavailable'),
      storage: storage,
    );

    await t.runAsync(host.onFillAll);

    expect(host.status, startsWith('Fill all failed'));
    expect(host.publishes, 1, reason: 'a partial batch must still sync');
    expect(host.fillFlow.busy, isFalse);
  });
}
