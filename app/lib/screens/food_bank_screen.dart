/// Food bank browser: lists every entry across the log-derived and manual
/// banks with filtering, sorting, and the ability to add new manual entries.
library;

import 'dart:async';

import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Filter / sort state
// ---------------------------------------------------------------------------

/// Sort field for the food bank list.
enum FbSortField {
  /// Sort alphabetically by name.
  name,

  /// Sort by calories.
  kcal,

  /// Sort by protein (g).
  protein,

  /// Sort by carbohydrates (g).
  carbs,

  /// Sort by fat (g).
  fat,

  /// Sort by usage count (most-used first by default).
  count,
}

/// Active filter criteria for the food bank list.
class FbFilter {
  /// Creates a [FbFilter] with the given criteria.
  FbFilter({
    this.nameQuery = '',
    this.minKcal,
    this.maxKcal,
    this.minProtein,
    this.maxProtein,
    this.minCarbs,
    this.maxCarbs,
    this.minFat,
    this.maxFat,
  });

  /// Substring match on the food name.
  String nameQuery;

  /// Minimum kcal.
  double? minKcal;

  /// Maximum kcal.
  double? maxKcal;

  /// Minimum protein (g).
  double? minProtein;

  /// Maximum protein (g).
  double? maxProtein;

  /// Minimum carbs (g).
  double? minCarbs;

  /// Maximum carbs (g).
  double? maxCarbs;

  /// Minimum fat (g).
  double? minFat;

  /// Maximum fat (g).
  double? maxFat;

  /// True when any criterion is set.
  bool get isActive =>
      nameQuery.isNotEmpty ||
      minKcal != null ||
      maxKcal != null ||
      minProtein != null ||
      maxProtein != null ||
      minCarbs != null ||
      maxCarbs != null ||
      minFat != null ||
      maxFat != null;
}

// ---------------------------------------------------------------------------
// Pure filter / sort helper
// ---------------------------------------------------------------------------

/// Filters and sorts [entries] by [filter] and [sortField]/[ascending].
///
/// Exposed as a top-level function for unit tests.
List<FoodBankRecord> applyFbFilter(
  List<FoodBankRecord> entries,
  FbFilter filter,
  FbSortField sortField, {
  required bool ascending,
}) {
  var result = [...entries];
  if (filter.nameQuery.isNotEmpty) {
    final q = filter.nameQuery.toLowerCase();
    result = result.where((e) => e.desc.toLowerCase().contains(q)).toList();
  }
  if (filter.minKcal != null) {
    result = result.where((e) => e.kcal >= filter.minKcal!).toList();
  }
  if (filter.maxKcal != null) {
    result = result.where((e) => e.kcal <= filter.maxKcal!).toList();
  }
  if (filter.minProtein != null) {
    result = result.where((e) => e.proteinG >= filter.minProtein!).toList();
  }
  if (filter.maxProtein != null) {
    result = result.where((e) => e.proteinG <= filter.maxProtein!).toList();
  }
  if (filter.minCarbs != null) {
    result = result.where((e) => e.carbsG >= filter.minCarbs!).toList();
  }
  if (filter.maxCarbs != null) {
    result = result.where((e) => e.carbsG <= filter.maxCarbs!).toList();
  }
  if (filter.minFat != null) {
    result = result.where((e) => e.fatG >= filter.minFat!).toList();
  }
  if (filter.maxFat != null) {
    result = result.where((e) => e.fatG <= filter.maxFat!).toList();
  }

  result.sort((a, b) {
    int cmp;
    switch (sortField) {
      case FbSortField.name:
        cmp = a.desc.compareTo(b.desc);
      case FbSortField.kcal:
        cmp = a.kcal.compareTo(b.kcal);
      case FbSortField.protein:
        cmp = a.proteinG.compareTo(b.proteinG);
      case FbSortField.carbs:
        cmp = a.carbsG.compareTo(b.carbsG);
      case FbSortField.fat:
        cmp = a.fatG.compareTo(b.fatG);
      case FbSortField.count:
        cmp = a.count.compareTo(b.count);
    }
    return ascending ? cmp : -cmp;
  });

  return result;
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

/// Lists all food bank entries (log-derived + manual) with filtering/sorting
/// and a FAB for adding new manual entries.
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
        builder: (ctx, setSheet) => _FbFilterSheet(
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

  Future<void> _openAddDialog() async {
    final result = await showDialog<FoodBankRecord>(
      context: context,
      builder: (_) => const _AddEntryDialog(),
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
          : ListView.builder(
              itemCount: _displayed.length,
              itemBuilder: (context, i) => _RecordTile(_displayed[i]),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAddDialog,
        tooltip: 'Add manual entry',
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Record tile
// ---------------------------------------------------------------------------

class _RecordTile extends StatelessWidget {
  const _RecordTile(this.record);
  final FoodBankRecord record;

  @override
  Widget build(BuildContext context) {
    final macros =
        'P ${record.proteinG.toStringAsFixed(0)} g  '
        'C ${record.carbsG.toStringAsFixed(0)} g  '
        'F ${record.fatG.toStringAsFixed(0)} g';
    final per = record.grams > 0
        ? ' per ${record.grams.toStringAsFixed(0)} g'
        : '';
    return ListTile(
      title: Text(record.desc),
      subtitle: Text(
        '${record.kcal.toStringAsFixed(0)} kcal$per  ·  $macros',
      ),
      trailing: record.count > 0
          ? Text(
              '×${record.count.toStringAsFixed(0)}',
              style: Theme.of(context).textTheme.bodySmall,
            )
          : null,
    );
  }
}

// ---------------------------------------------------------------------------
// Filter sheet
// ---------------------------------------------------------------------------

class _FbFilterSheet extends StatelessWidget {
  const _FbFilterSheet({
    required this.filter,
    required this.sortField,
    required this.ascending,
    required this.maxKcal,
    required this.maxProtein,
    required this.maxCarbs,
    required this.maxFat,
    required this.onFilterChanged,
    required this.onSortChanged,
    required this.onApply,
    required this.onClear,
  });

  final FbFilter filter;
  final FbSortField sortField;
  final bool ascending;
  final double maxKcal;
  final double maxProtein;
  final double maxCarbs;
  final double maxFat;
  final void Function(FbFilter) onFilterChanged;
  final void Function({required FbSortField field, required bool asc})
  onSortChanged;
  final VoidCallback onApply;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Filter & Sort',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: onClear,
                  child: const Text('Clear all'),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'Search by name',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                  controller: TextEditingController(text: filter.nameQuery)
                    ..selection = TextSelection.collapsed(
                      offset: filter.nameQuery.length,
                    ),
                  onChanged: (v) {
                    filter.nameQuery = v;
                    onFilterChanged(filter);
                  },
                ),
                const SizedBox(height: 16),
                if (maxKcal > 0) ...[
                  Text(
                    'Kcal range',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  RangeSlider(
                    max: maxKcal,
                    values: RangeValues(
                      filter.minKcal ?? 0,
                      filter.maxKcal ?? maxKcal,
                    ),
                    labels: RangeLabels(
                      (filter.minKcal ?? 0).toStringAsFixed(0),
                      (filter.maxKcal ?? maxKcal).toStringAsFixed(0),
                    ),
                    onChanged: (v) {
                      filter.minKcal = v.start > 0 ? v.start : null;
                      filter.maxKcal = v.end < maxKcal ? v.end : null;
                      onFilterChanged(filter);
                    },
                  ),
                  const SizedBox(height: 8),
                ],
                if (maxProtein > 0) ...[
                  Text(
                    'Protein range (g)',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  RangeSlider(
                    max: maxProtein,
                    values: RangeValues(
                      filter.minProtein ?? 0,
                      filter.maxProtein ?? maxProtein,
                    ),
                    labels: RangeLabels(
                      (filter.minProtein ?? 0).toStringAsFixed(0),
                      (filter.maxProtein ?? maxProtein).toStringAsFixed(0),
                    ),
                    onChanged: (v) {
                      filter.minProtein = v.start > 0 ? v.start : null;
                      filter.maxProtein = v.end < maxProtein ? v.end : null;
                      onFilterChanged(filter);
                    },
                  ),
                  const SizedBox(height: 8),
                ],
                if (maxCarbs > 0) ...[
                  Text(
                    'Carbs range (g)',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  RangeSlider(
                    max: maxCarbs,
                    values: RangeValues(
                      filter.minCarbs ?? 0,
                      filter.maxCarbs ?? maxCarbs,
                    ),
                    labels: RangeLabels(
                      (filter.minCarbs ?? 0).toStringAsFixed(0),
                      (filter.maxCarbs ?? maxCarbs).toStringAsFixed(0),
                    ),
                    onChanged: (v) {
                      filter.minCarbs = v.start > 0 ? v.start : null;
                      filter.maxCarbs = v.end < maxCarbs ? v.end : null;
                      onFilterChanged(filter);
                    },
                  ),
                  const SizedBox(height: 8),
                ],
                if (maxFat > 0) ...[
                  Text(
                    'Fat range (g)',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  RangeSlider(
                    max: maxFat,
                    values: RangeValues(
                      filter.minFat ?? 0,
                      filter.maxFat ?? maxFat,
                    ),
                    labels: RangeLabels(
                      (filter.minFat ?? 0).toStringAsFixed(0),
                      (filter.maxFat ?? maxFat).toStringAsFixed(0),
                    ),
                    onChanged: (v) {
                      filter.minFat = v.start > 0 ? v.start : null;
                      filter.maxFat = v.end < maxFat ? v.end : null;
                      onFilterChanged(filter);
                    },
                  ),
                  const SizedBox(height: 8),
                ],
                Text(
                  'Sort by',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButton<FbSortField>(
                        isExpanded: true,
                        value: sortField,
                        items: const [
                          DropdownMenuItem(
                            value: FbSortField.count,
                            child: Text('Usage count'),
                          ),
                          DropdownMenuItem(
                            value: FbSortField.name,
                            child: Text('Name'),
                          ),
                          DropdownMenuItem(
                            value: FbSortField.kcal,
                            child: Text('Kcal'),
                          ),
                          DropdownMenuItem(
                            value: FbSortField.protein,
                            child: Text('Protein'),
                          ),
                          DropdownMenuItem(
                            value: FbSortField.carbs,
                            child: Text('Carbs'),
                          ),
                          DropdownMenuItem(
                            value: FbSortField.fat,
                            child: Text('Fat'),
                          ),
                        ],
                        onChanged: (v) {
                          if (v != null) {
                            onSortChanged(field: v, asc: ascending);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(
                        ascending ? Icons.arrow_upward : Icons.arrow_downward,
                      ),
                      tooltip: ascending ? 'Ascending' : 'Descending',
                      onPressed: () =>
                          onSortChanged(field: sortField, asc: !ascending),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onApply,
                child: const Text('Apply'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Add entry dialog
// ---------------------------------------------------------------------------

class _AddEntryDialog extends StatefulWidget {
  const _AddEntryDialog();

  @override
  State<_AddEntryDialog> createState() => _AddEntryDialogState();
}

class _AddEntryDialogState extends State<_AddEntryDialog> {
  final _name = TextEditingController();
  final _grams = TextEditingController(text: '100');
  final _kcal = TextEditingController();
  final _protein = TextEditingController();
  final _carbs = TextEditingController();
  final _fat = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _grams.dispose();
    _kcal.dispose();
    _protein.dispose();
    _carbs.dispose();
    _fat.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(
      FoodBankRecord(
        desc: name,
        kcal: double.tryParse(_kcal.text) ?? 0,
        proteinG: double.tryParse(_protein.text) ?? 0,
        carbsG: double.tryParse(_carbs.text) ?? 0,
        fatG: double.tryParse(_fat.text) ?? 0,
        grams: double.tryParse(_grams.text) ?? 100,
        count: 0,
      ),
    );
  }

  Widget _field(String label, TextEditingController ctrl) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextField(
      controller: ctrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, isDense: true),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add to food bank'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  isDense: true,
                ),
              ),
            ),
            _field('Reference grams', _grams),
            _field('Kcal', _kcal),
            _field('Protein (g)', _protein),
            _field('Carbs (g)', _carbs),
            _field('Fat (g)', _fat),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _save,
          child: const Text('Save to bank'),
        ),
      ],
    );
  }
}
