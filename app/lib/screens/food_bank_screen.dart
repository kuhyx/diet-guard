/// Food bank browser: lists every entry across the log-derived and manual
/// banks with filtering, sorting, and the ability to add new manual entries.
///
/// The filter model, the filter sheet and the add-entry dialog live under
/// `lib/widgets/food_bank/` (split for the repo's 250-line cap); this file is
/// the screen that wires them together.
library;

import 'dart:async';

import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/widgets/food_bank/fb_add_entry_dialog.dart';
import 'package:diet_guard_app/widgets/food_bank/fb_filter.dart';
import 'package:diet_guard_app/widgets/food_bank/fb_filter_sheet.dart';
import 'package:diet_guard_app/widgets/food_bank/fb_record_tile.dart';
import 'package:diet_guard_app/widgets/food_bank/fb_tile_grid.dart';
import 'package:flutter/material.dart';

/// Browses every banked food -- log-derived and manually curated -- with
/// filtering, sorting, and an add-entry dialog.
class FoodBankScreen extends StatefulWidget {
  /// Creates a [FoodBankScreen].
  const FoodBankScreen({super.key});

  @override
  State<FoodBankScreen> createState() => _FoodBankScreenState();
}

class _FoodBankScreenState extends State<FoodBankScreen> {
  List<FoodBankRecord>? _allEntries;
  List<FoodBankRecord> _displayed = const [];
  FbFilter _filter = FbFilter();
  FbSortField _sortField = FbSortField.count;
  bool _sortAscending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final entries = await FoodBankService.instance.mergedEntries();
    if (!mounted) return;
    setState(() {
      _allEntries = entries;
      _displayed = applyFbFilter(
        entries,
        _filter,
        _sortField,
        ascending: _sortAscending,
      );
    });
  }

  void _applyFilterSort() {
    setState(() {
      _displayed = applyFbFilter(
        _allEntries!,
        _filter,
        _sortField,
        ascending: _sortAscending,
      );
    });
  }

  Future<void> _openFilterSheet() async {
    final all = _allEntries!;

    double maxVal(double Function(FoodBankRecord) f, double fallback) =>
        all.isEmpty ? fallback : all.map(f).reduce((a, b) => a > b ? a : b);

    final maxKcal = maxVal((e) => e.kcal, 2000);
    final maxProtein = maxVal((e) => e.proteinG, 200);
    final maxCarbs = maxVal((e) => e.carbsG, 200);
    final maxFat = maxVal((e) => e.fatG, 100);

    var draft = FbFilter(
      nameQuery: _filter.nameQuery,
      minKcal: _filter.minKcal,
      maxKcal: _filter.maxKcal,
      minProtein: _filter.minProtein,
      maxProtein: _filter.maxProtein,
      minCarbs: _filter.minCarbs,
      maxCarbs: _filter.maxCarbs,
      minFat: _filter.minFat,
      maxFat: _filter.maxFat,
    );
    var draftSort = _sortField;
    var draftAsc = _sortAscending;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => FbFilterSheet(
          filter: draft,
          sortField: draftSort,
          ascending: draftAsc,
          maxKcal: maxKcal,
          maxProtein: maxProtein,
          maxCarbs: maxCarbs,
          maxFat: maxFat,
          onFilterChanged: (f) => setSheet(() => draft = f),
          onSortChanged: ({required field, required asc}) {
            setSheet(() {
              draftSort = field;
              draftAsc = asc;
            });
          },
          onApply: () {
            setState(() {
              _filter = draft;
              _sortField = draftSort;
              _sortAscending = draftAsc;
            });
            _applyFilterSort();
            Navigator.of(ctx).pop();
          },
          onClear: () {
            setSheet(() {
              draft = FbFilter();
              draftSort = FbSortField.count;
              draftAsc = false;
            });
          },
        ),
      ),
    );
  }

  /// Shows the full macro line for a tapped tile.
  Future<void> _openDetail(FoodBankRecord record) => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (_) => SafeArea(child: RecordTile(record)),
  );

  Future<void> _openAddDialog() async {
    final result = await showDialog<FoodBankRecord>(
      context: context,
      builder: (_) => const AddEntryDialog(),
    );
    if (result == null) return;
    await FoodBankService.instance.addManualEntry(result);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final all = _allEntries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Food Bank'),
        actions: [
          if (all != null)
            Stack(
              alignment: Alignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.filter_list),
                  tooltip: 'Filter & sort',
                  onPressed: _openFilterSheet,
                ),
                if (_filter.isActive)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.error,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
      body: all == null
          ? const Center(child: CircularProgressIndicator())
          : _displayed.isEmpty
          ? Center(
              child: Text(
                all.isEmpty
                    ? 'Food bank is empty.\n'
                          'Log meals to populate it, or add entries manually.'
                    : 'No entries match the current filter.',
                textAlign: TextAlign.center,
              ),
            )
          : FbTileGrid(records: _displayed, onOpen: _openDetail),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAddDialog,
        tooltip: 'Add manual entry',
        child: const Icon(Icons.add),
      ),
    );
  }
}
