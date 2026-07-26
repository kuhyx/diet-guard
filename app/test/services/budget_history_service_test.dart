import 'dart:convert';
import 'dart:io';

import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/budget_schedule.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_hist_');
    BudgetHistoryService.resetForTesting(store: FileDocumentStore(tempDir));
  });

  tearDown(() async {
    BudgetHistoryService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  test('schedule is empty when the singleton is uninitialised', () {
    BudgetHistoryService.resetForTesting();
    expect(BudgetHistoryService.schedule.entries, isEmpty);
    expect(BudgetHistoryService.schedule.forDay('2026-06-01'), 2200);
  });

  test('seedIfEmpty grandfathers the current value to the epoch', () async {
    await BudgetHistoryService.instance.seedIfEmpty(
      2200,
      DateTime.utc(2026, 7, 13),
    );

    expect(BudgetHistoryService.schedule.forDay('2026-06-01'), 2200);
    expect(
      BudgetHistoryService.schedule.entries.single.effectiveFrom,
      kEpochDay,
    );
  });

  test('seedIfEmpty does nothing when the goal was never set', () async {
    // A null updatedAt means this device has nothing of its own to
    // grandfather; the default fallback already covers every day.
    await BudgetHistoryService.instance.seedIfEmpty(2200, null);
    expect(BudgetHistoryService.schedule.entries, isEmpty);
  });

  test('seedIfEmpty never overwrites an existing history', () async {
    await BudgetHistoryService.instance.recordChange(
      1800,
      when: DateTime(2026, 7, 26),
    );
    await BudgetHistoryService.instance.seedIfEmpty(
      2200,
      DateTime.utc(2026, 7, 13),
    );
    expect(BudgetHistoryService.schedule.entries, hasLength(1));
    expect(BudgetHistoryService.schedule.entries.single.kcal, 1800);
  });

  test('recordChange persists and reloads', () async {
    await BudgetHistoryService.instance.recordChange(
      2000,
      when: DateTime(2026, 7, 26),
    );

    await BudgetHistoryService.initForTesting(FileDocumentStore(tempDir));

    expect(BudgetHistoryService.schedule.forDay('2026-07-26'), 2000);
  });

  test('overlapping same-day writes leave exactly one entry', () async {
    // settings_screen saves as the user types, so several of these are in
    // flight at once; the service serializes its whole in-memory schedule
    // rather than read-modify-writing, so they cannot race into duplicates.
    final when = DateTime(2026, 7, 26, 12);
    await Future.wait([
      BudgetHistoryService.instance.recordChange(2, when: when),
      BudgetHistoryService.instance.recordChange(20, when: when),
      BudgetHistoryService.instance.recordChange(200, when: when),
      BudgetHistoryService.instance.recordChange(2000, when: when),
    ]);

    expect(BudgetHistoryService.schedule.entries, hasLength(1));
  });

  test('applyMerged replaces the stored history', () async {
    await BudgetHistoryService.instance.recordChange(
      1800,
      when: DateTime(2026, 7, 26),
    );

    await BudgetHistoryService.instance.applyMerged([
      const BudgetEntry(
        effectiveFrom: kEpochDay,
        kcal: 2200,
        editedAt: '2026-07-13T00:00:00.000Z',
      ),
    ]);

    expect(BudgetHistoryService.schedule.entries.single.kcal, 2200);
  });

  test('a corrupt document degrades to no history', () async {
    await File(
      '${tempDir.path}/budget_history.json',
    ).writeAsString('not json{{{');

    await BudgetHistoryService.initForTesting(FileDocumentStore(tempDir));

    expect(BudgetHistoryService.schedule.entries, isEmpty);
  });

  test('an absent document loads as no history', () async {
    await BudgetHistoryService.initForTesting(FileDocumentStore(tempDir));
    expect(BudgetHistoryService.schedule.entries, isEmpty);
  });

  test('the stored document is plain readable JSON', () async {
    await BudgetHistoryService.instance.recordChange(
      2000,
      when: DateTime(2026, 7, 26),
    );

    final raw = await File(
      '${tempDir.path}/budget_history.json',
    ).readAsString();
    final data = jsonDecode(raw) as Map;
    expect(data['v'], 1);
    expect((data['e'] as Map)['2026-07-26'], isA<Map>());
  });
}
