// Guard: the Body screen, every tile sheet and the activity-method chooser
// paint no words (only numbers, unit symbols, MET and workout labels).
// Workout labels are content only for manual workouts (source == 'manual').

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'label_finders.dart';
import 'no_words_support.dart';
import 'screens/body_screen_support.dart';

/// Workout labels the PC published (content, see `seedPerson`), plus the
/// proper names of the BMI / ideal-weight / BMR formulas that label their
/// figures (DOUBT rows in keep.md: kept from the first pilot, outside the
/// activity sheet). Activity formulas (ACSM, Per-km) are NOT here: that sheet
/// and its chooser show glyphs only. Only manual workouts carry human content.
const Set<String> _workouts = {
  'walk to the shop',
  'Harris-Benedict (revised 1984)',
  'Peterson (BMI 22)',
  'Mifflin-St Jeor',
  'Katch-McArdle',
  'Cunningham',
  'BMI Prime',
  'Trefethen',
  'Devine',
  'Robinson',
  'Miller',
};

void main() {
  late MemoryDocStore store;

  setUp(() async {
    store = MemoryDocStore();
    await setUpBodyServices(store);
  });
  tearDown(tearDownBodyServices);

  test('the checker flags an injected word (canary)', () {
    expect(wordsIn('70.0 kg'), isEmpty);
    expect(wordsIn('265 MET'), isEmpty);
    expect(wordsIn('Measured (ACSM)'), isNotEmpty);
    expect(wordsIn('walk to the shop 4 km', content: _workouts), ['km']);
    expect(wordsIn('walk to the shop', content: _workouts), isEmpty);
  });

  testWidgets('canary: a painted word fails the guard', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Text('Activity')));
    expect(() => expectNoWords(tester), throwsA(isA<TestFailure>()));
  });

  for (final seeded in [false, true]) {
    testWidgets('body tiles and sheets paint no words (seeded: $seeded)', (
      tester,
    ) async {
      if (seeded) await seedPerson(store);
      await pumpBody(tester);
      final found = wordyStrings(
        tester,
        content: _workouts,
        minStrings: 5,
        where: 'tiles',
      );
      for (final title in tileTitles(tester)) {
        await openTile(tester, title);
        found.addAll(wordyStrings(tester, content: _workouts, where: title));
        await closeSheet(tester);
      }
      expect(found, isEmpty);
    });
  }

  testWidgets('the activity-method chooser paints no words', (tester) async {
    await seedPerson(store);
    await pumpBody(tester);
    await openTile(tester, 'Daily calorie target');
    await tester.tap(bySemLabel('Moderate').first);
    await tester.pumpAndSettle();
    expectNoWords(
      tester,
      content: _workouts,
      minStrings: 8,
      where: 'activity chooser',
    );
    await tester.tap(bySemLabel('Measured (ACSM)').last);
    await tester.pumpAndSettle();
    expectNoWords(tester, content: _workouts, where: 'measured goal');
  });
}
