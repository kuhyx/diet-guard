/// The delivered-dish queue as the log form actually drives it.
///
/// `kuchnia_queue_test.dart` covers the queue's own state machine. This file
/// covers the part that state machine exists for and that a queue-only test
/// cannot see: after a submit, are the **form controllers** already holding
/// the next dish?
///
/// That distinction is the whole point. On the PC this regressed once --
/// `_prefill_next_dish` briefly had exactly one caller, so the queue was
/// correct and the form was not. Every dish after the first stayed behind
/// another tap and the "(N more to go)" line became a dead letter. A test
/// asserting "the dish was offered" passes throughout that bug; one asserting
/// the controller contents after a submit does not.
///
/// Driven through a minimal host rather than the real `LogMealScreen`: that
/// screen's `initState` fans out into sync, notifications and the food bank,
/// and pumping it to quiescence in a widget test does not terminate. The
/// mixin is the unit that owns this behaviour, so it is the unit under test.
library;

import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/screens/log_meal_kuchnia_mixin.dart';
import 'package:diet_guard_app/services/document_store.dart';
import 'package:diet_guard_app/services/kuchnia_queue.dart';
import 'package:diet_guard_app/widgets/macro_input_row.dart';
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

/// The smallest widget that uses the mixin the way the log screen does.
class _Host extends StatefulWidget {
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with LogMealKuchniaMixin<_Host> {
  final TextEditingController desc = TextEditingController();
  final MacroControllers macros = MacroControllers();

  @override
  TextEditingController get descController => desc;

  @override
  MacroControllers get macroControllers => macros;

  /// Stands in for the screen's submit: the entry write is irrelevant here,
  /// the queue advance is what is under test.
  void submit() {
    final logged = desc.text;
    desc.clear();
    macros.clear();
    advanceQueueAfterLog(logged);
  }

  @override
  Widget build(BuildContext context) =>
      Text(queueStatusLine ?? '', textDirection: TextDirection.ltr);
}

KuchniaDish _dish(String name, int priority) => KuchniaDish(
  name: name,
  kcal: 400,
  proteinG: 25,
  carbsG: 45.5,
  fatG: 12,
  grams: 300,
  priority: priority,
  slotLabel: 'Obiad',
);

void main() {
  late _HostState host;

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: _Host()));
    host = tester.state(find.byType(_Host));
  }

  setUp(() async {
    await KuchniaQueueService.initForTesting(_MemoryStore());
  });

  tearDown(KuchniaQueueService.resetForTesting);

  testWidgets('after a submit the form already holds the next dish', (
    tester,
  ) async {
    await pumpHost(tester);
    KuchniaQueueService.instance.offer([
      _dish('Pancakes', 1),
      _dish('Kaszotto', 2),
    ]);
    host.prefillNextDish();
    await tester.pump();
    expect(host.desc.text, 'Pancakes');

    host.submit();
    await tester.pump();

    expect(
      host.desc.text,
      'Kaszotto',
      reason: 'the form must already hold dish 2. Empty here means the queue '
          'is right and the form is not -- the dead-letter regression where '
          'every dish after the first waits behind another tap.',
    );
    expect(KuchniaQueueService.remaining, 1);
  });

  testWidgets('the macros come with the dish, not just the name', (
    tester,
  ) async {
    await pumpHost(tester);
    KuchniaQueueService.instance.offer([_dish('Pancakes', 1)]);
    host.prefillNextDish();
    await tester.pump();

    // Whole numbers print without a trailing `.0`, matching Python's `:g`.
    expect(host.macros.kcal.text, '400');
    expect(host.macros.protein.text, '25');
    expect(host.macros.carbs.text, '45.5');
    expect(host.macros.fat.text, '12');
    expect(host.macros.grams.text, '300');
  });

  testWidgets('the leftover dish is named rather than dropped', (tester) async {
    // Five delivered meals against four default slots leaves one queued when
    // the last slot is logged. It is already banked, so say so.
    await pumpHost(tester);
    KuchniaQueueService.instance.offer([_dish('A', 1), _dish('B', 2)]);
    host.prefillNextDish();
    await tester.pump();

    host.submit();
    await tester.pump();

    expect(find.text('1 more delivered dish to log.'), findsOneWidget);
  });

  testWidgets('editing the description does not consume the offer', (
    tester,
  ) async {
    // What the user logged was not the delivered dish, so marking it eaten
    // would lose a real delivered meal silently.
    await pumpHost(tester);
    KuchniaQueueService.instance.offer([_dish('Pancakes', 1)]);
    host.prefillNextDish();
    await tester.pump();

    host.desc.text = 'Something else';
    host.submit();
    await tester.pump();

    expect(KuchniaQueueService.remaining, 1);
  });

  testWidgets('an empty queue clears the offer instead of throwing', (
    tester,
  ) async {
    await pumpHost(tester);
    host.prefillNextDish();
    await tester.pump();
    expect(host.offeredDish, isNull);
    expect(host.queueStatusLine, isNull);
  });

  testWidgets('submitting with nothing offered is a no-op', (tester) async {
    await pumpHost(tester);
    host.submit();
    await tester.pump();
    expect(KuchniaQueueService.remaining, 0);
  });
}
