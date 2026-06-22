/// Single-food meal logging screen -- the app's primary, done-criterion
/// screen: "I can open the diet app on my phone and fill meal I ate."
library;

import 'dart:async';

import 'package:diet_guard_app/models/food_suggestion.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/screens/meal_builder_screen.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/widgets/autocomplete_suggestion_list.dart';
import 'package:diet_guard_app/widgets/macro_input_row.dart';
import 'package:diet_guard_app/widgets/slot_status_bar.dart';
import 'package:flutter/material.dart';

/// Lets the user log one food item, with food-bank autocomplete and
/// today's slot status, or hop into [MealBuilderScreen] for a composite
/// multi-item meal.
class LogMealScreen extends StatefulWidget {
  /// Creates a [LogMealScreen].
  const LogMealScreen({super.key});

  @override
  State<LogMealScreen> createState() => _LogMealScreenState();
}

class _LogMealScreenState extends State<LogMealScreen> {
  final TextEditingController _descController = TextEditingController();
  final MacroControllers _macros = MacroControllers();
  List<FoodSuggestion> _suggestions = const [];
  Set<int> _loggedSlots = {};
  String _source = 'manual';
  String? _status;

  @override
  void initState() {
    super.initState();
    _descController.addListener(_onDescChanged);
    for (final controller in [
      _macros.kcal,
      _macros.protein,
      _macros.carbs,
      _macros.fat,
      _macros.perGrams,
      _macros.grams,
    ]) {
      controller.addListener(_onMacroEdited);
    }
    unawaited(_refreshSlots());
    unawaited(_onDescChanged());
  }

  @override
  void dispose() {
    _descController.dispose();
    _macros.dispose();
    super.dispose();
  }

  Future<void> _refreshSlots() async {
    final logged = await LogStorageService.instance.loggedSlotsToday();
    if (!mounted) return;
    setState(() => _loggedSlots = logged);
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

  double _parse(TextEditingController controller) =>
      double.tryParse(controller.text.trim()) ?? 0;

  Future<void> _onLogMeal() async {
    final desc = _descController.text.trim();
    if (desc.isEmpty) {
      setState(() => _status = 'Type what you ate first.');
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
    final slot = currentSlot(DateTime.now());
    await LogStorageService.instance.logMeal(desc, nutrition, slot: slot);
    final log = await LogStorageService.instance.readLog();
    await FoodBankService.instance.rebuildAndPersist(log);
    if (!mounted) return;
    _descController.clear();
    _macros.clear();
    setState(() => _source = 'manual');
    await _refreshSlots();
    if (!mounted) return;
    setState(() => _status = 'Logged "$desc".');
  }

  Future<void> _onBuildMeal() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const MealBuilderScreen()),
    );
    await _refreshSlots();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Diet Guard')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SlotStatusBar(now: DateTime.now(), loggedSlots: _loggedSlots),
            const SizedBox(height: 16),
            TextField(
              controller: _descController,
              decoration: const InputDecoration(labelText: 'What did you eat?'),
            ),
            AutocompleteSuggestionList(
              suggestions: _suggestions,
              onSelected: _onSuggestionSelected,
            ),
            const SizedBox(height: 12),
            MacroInputRow(controllers: _macros),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _onLogMeal,
                  child: const Text('Log meal'),
                ),
                OutlinedButton(
                  onPressed: _onBuildMeal,
                  child: const Text('Build a multi-item meal'),
                ),
              ],
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
