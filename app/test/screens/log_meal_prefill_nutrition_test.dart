/// What a prefilled dish actually *logs*, as distinct from what it displays.
///
/// Split from `log_meal_kuchnia_mixin_test.dart` (250-line cap) along the
/// seam the 2026-08-23 corruption exposed: that file asserts the queue's
/// mechanics and the controllers' text, and every one of its tests passed
/// while a delivered dish logged 2.58x its real calories. The bug lived in
/// the *computed* `Nutrition`, which nothing there looked at.
///
/// So these tests assert the computed value, never the field text.
library;

import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/screens/log_meal_actions.dart';
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
  void initState() {
    super.initState();
    for (final c in [
      macros.kcal,
      macros.protein,
      macros.carbs,
      macros.fat,
      macros.perGrams,
      macros.grams,
    ]) {
      c.addListener(() {
        if (source == 'food bank') source = 'manual';
      });
    }
  }

  @override
  TextEditingController get descController => desc;

  @override
  MacroControllers get macroControllers => macros;

  /// Mirrors the screen: a macro edit demotes a food-bank pick to manual,
  /// and a prefilled dish stamps catering.
  String source = 'manual';

  @override
  void onDishPrefilled() => source = 'catering';

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

  testWidgets('a stale per-grams does not rescale the prefilled dish', (
    tester,
  ) async {
    // The 2026-08-23 corruption: a food-bank pick leaves `perGrams` at 100,
    // the dish prefills over it without clearing, and `nutritionForPortion`
    // reads the dish's *per-portion* macros as *per-100g* and multiplies them
    // by 300/100. Asserting controller text passes throughout that bug --
    // only the computed Nutrition sees it.
    await pumpHost(tester);
    host.macros.perGrams.text = '100';

    KuchniaQueueService.instance.offer([_dish('Pancakes', 1)]);
    host.prefillNextDish();
    await tester.pump();

    final nutrition = nutritionFromControllers(host.macros, 'kuchnia wikinga');
    expect(
      nutrition.kcal,
      400,
      reason: 'the dish must log its own calories. 1200 here is the stale '
          'per-grams rescaling a per-portion dish by 300/100.',
    );
    expect(nutrition.proteinG, 25);
    expect(nutrition.carbsG, 45.5);
    expect(nutrition.fatG, 12);
    expect(nutrition.grams, 300);
  });

  testWidgets('clear() empties every macro controller', (tester) async {
    // Enumerated deliberately: the bug was a *forgotten* field, so a new
    // seventh controller must fail this until it is cleared too.
    await pumpHost(tester);
    final controllers = <String, TextEditingController>{
      'kcal': host.macros.kcal,
      'protein': host.macros.protein,
      'carbs': host.macros.carbs,
      'fat': host.macros.fat,
      'perGrams': host.macros.perGrams,
      'grams': host.macros.grams,
    };
    for (final c in controllers.values) {
      c.text = '99';
    }

    host.macros.clear();

    controllers.forEach((name, c) {
      expect(c.text, isEmpty, reason: '$name survived clear()');
    });
  });

  testWidgets('the prefill stamps catering even though clearing demotes it', (
    tester,
  ) async {
    // Ordering is load-bearing and invisible: `clear()` fires the macro
    // listener, which demotes a food-bank pick to 'manual'. `onDishPrefilled`
    // runs after and must have the last word, or a delivered dish logs as a
    // manual entry and the queue never advances.
    await pumpHost(tester);
    host.source = 'food bank';
    host.macros.perGrams.text = '100';

    KuchniaQueueService.instance.offer([_dish('Pancakes', 1)]);
    host.prefillNextDish();
    await tester.pump();

    expect(host.source, 'catering');
  });
}
