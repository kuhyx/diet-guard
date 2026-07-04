/// Screen for editing an existing meal-history entry in-place.
library;

import 'dart:async';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/food_suggestion.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/widgets/autocomplete_suggestion_list.dart';
import 'package:diet_guard_app/widgets/macro_input_row.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

/// Edit screen for an existing [FoodEntry].
///
/// Preserves [FoodEntry.id], [FoodEntry.time], [FoodEntry.slot],
/// [FoodEntry.imagePath], and [FoodEntry.deleted]. All nutritional fields and
/// the description are editable.
class EditEntryScreen extends StatefulWidget {
  /// Creates an [EditEntryScreen] pre-filled with [entry].
  const EditEntryScreen({required this.entry, super.key});

  /// The entry to edit.
  final FoodEntry entry;

  @override
  State<EditEntryScreen> createState() => _EditEntryScreenState();
}

class _EditEntryScreenState extends State<EditEntryScreen> {
  late final TextEditingController _descController;
  final MacroControllers _macros = MacroControllers();
  List<FoodSuggestion> _suggestions = const [];
  String _source = 'manual';
  String? _status;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _descController = TextEditingController(text: e.desc);
    _macros.kcal.text = e.kcal.toStringAsFixed(0);
    _macros.protein.text = e.proteinG.toStringAsFixed(0);
    _macros.carbs.text = e.carbsG.toStringAsFixed(0);
    _macros.fat.text = e.fatG.toStringAsFixed(0);
    _macros.grams.text = e.grams > 0 ? e.grams.toStringAsFixed(0) : '';
    _source = e.source;

    _descController.addListener(_onDescChanged);
    for (final c in [
      _macros.kcal,
      _macros.protein,
      _macros.carbs,
      _macros.fat,
      _macros.perGrams,
      _macros.grams,
    ]) {
      c.addListener(_onMacroEdited);
    }
    unawaited(_onDescChanged());
  }

  @override
  void dispose() {
    _descController.dispose();
    _macros.dispose();
    super.dispose();
  }

  void _onMacroEdited() {
    if (_source == 'food bank') {
      setState(() => _source = 'manual');
    }
  }

  Future<void> _onDescChanged() async {
    final matches = await FoodBankService.instance.search(
      _descController.text,
    );
    if (!mounted) return;
    setState(() => _suggestions = matches);
  }

  void _onSuggestionSelected(FoodSuggestion suggestion) {
    _descController.text = suggestion.name;
    _macros.kcal.text = suggestion.nutrition.kcal.toStringAsFixed(0);
    _macros.protein.text = suggestion.nutrition.proteinG.toStringAsFixed(0);
    _macros.carbs.text = suggestion.nutrition.carbsG.toStringAsFixed(0);
    _macros.fat.text = suggestion.nutrition.fatG.toStringAsFixed(0);
    _macros.perGrams.text = suggestion.nutrition.grams.toStringAsFixed(0);
    _macros.grams.text = suggestion.nutrition.grams.toStringAsFixed(0);
    setState(() {
      _source = 'food bank';
      _suggestions = const [];
    });
  }

  double _parse(TextEditingController c) => double.tryParse(c.text.trim()) ?? 0;

  Future<void> _onSave() async {
    final desc = _descController.text.trim();
    if (desc.isEmpty) {
      setState(() => _status = 'Description cannot be empty.');
      return;
    }
    final nutrition = nutritionForPortion(
      kcal: _parse(_macros.kcal),
      proteinG: _parse(_macros.protein),
      carbsG: _parse(_macros.carbs),
      fatG: _parse(_macros.fat),
      perGrams: _parse(_macros.perGrams),
      ateGrams: _parse(_macros.grams),
      source: _source,
    );
    final e = widget.entry;
    final updated = FoodEntry(
      // Assign a UUID when editing a legacy entry that never had one.
      // This upgrades it to a first-class sync entry without creating a
      // duplicate: the Python sync deduplicates null-id entries by time+desc.
      id: e.id ?? const Uuid().v4(),
      time: e.time,
      desc: desc,
      grams: nutrition.grams,
      kcal: nutrition.kcal,
      proteinG: nutrition.proteinG,
      carbsG: nutrition.carbsG,
      fatG: nutrition.fatG,
      source: _source,
      slot: e.slot,
      imagePath: e.imagePath,
    );
    await LogStorageService.instance.updateEntry(e, updated);
    final log = await LogStorageService.instance.readLog();
    await FoodBankService.instance.rebuildAndPersist(log);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit meal')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _descController,
              decoration: const InputDecoration(
                labelText: 'What did you eat?',
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: AutocompleteSuggestionList(
                suggestions: _suggestions,
                onSelected: _onSuggestionSelected,
              ),
            ),
            const SizedBox(height: 12),
            MacroInputRow(controllers: _macros),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _onSave,
                child: const Text('Save'),
              ),
            ),
            if (_status != null) ...[
              const SizedBox(height: 12),
              Text(_status!),
            ],
          ],
        ),
      ),
    );
  }
}
