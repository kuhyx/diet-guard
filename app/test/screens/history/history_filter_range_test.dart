import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/history_screen.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'history_test_support.dart';

void main() {
  useTempHistoryStores();
  testWidgets(
    '_formatDay falls back to raw key for an unparsable date (line 245)',
    (tester) async {
      await tester.runAsync(() async {
        // The day key is e.time.substring(0, 10). Writing an entry whose
        // `time` field can't be parsed by DateTime.parse exercises the
        // `on Exception` fallback in _formatDay (line 245), which returns the
        // raw key unchanged.  'NOT-A-DATE' is exactly 10 chars so substring
        // doesn't truncate it.
        await LogStorageService.instance.writeLog({
          'NOT-A-DATE': [
            const FoodEntry(
              id: 'bad1',
              time: 'NOT-A-DATE',
              desc: 'bad date entry',
              grams: 100,
              kcal: 100,
              proteinG: 5,
              carbsG: 10,
              fatG: 2,
              source: 'manual',
            ),
          ],
        });

        await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
        await settle(tester);

        // The raw key is shown as the day header when formatting fails.
        expect(find.text('NOT-A-DATE'), findsOneWidget);
      });
    },
  );
}
