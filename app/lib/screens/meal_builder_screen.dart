/// Composite multi-item meal flow, mirroring `_gatelock_mealflow.py`'s
/// add-item/log-meal loop.
library;

import 'package:diet_guard_app/models/meal_item.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/widgets/macro_input_row.dart';
import 'package:diet_guard_app/widgets/photo_attach_field.dart';
import 'package:flutter/material.dart';

/// A screen for building and logging a multi-item meal as one composite
/// entry, e.g. a dinner of soup + chicken + rice.
class MealBuilderScreen extends StatefulWidget {
  /// Creates a [MealBuilderScreen].
  const MealBuilderScreen({super.key});

  @override
  State<MealBuilderScreen> createState() => _MealBuilderScreenState();
}

class _MealBuilderScreenState extends State<MealBuilderScreen> {
  final TextEditingController _itemDescController = TextEditingController();
  final TextEditingController _mealNameController = TextEditingController();
  final MacroControllers _macros = MacroControllers();
  final List<MealItem> _items = [];
  String? _status;
  String? _imagePath;

  @override
  void dispose() {
    _itemDescController.dispose();
    _mealNameController.dispose();
    _macros.dispose();
    super.dispose();
  }

  double _parse(TextEditingController controller) =>
      double.tryParse(controller.text.trim()) ?? 0;

  void _onAddItem() {
    final desc = _itemDescController.text.trim();
    if (desc.isEmpty) {
      setState(() => _status = 'Type the item first, then add it.');
      return;
    }
    final nutrition = nutritionForPortion(
      kcal: _parse(_macros.kcal),
      proteinG: _parse(_macros.protein),
      carbsG: _parse(_macros.carbs),
      fatG: _parse(_macros.fat),
      perGrams: _parse(_macros.perGrams),
      ateGrams: _parse(_macros.grams),
      source: 'manual',
    );
    setState(() {
      _items.add(MealItem(name: desc, nutrition: nutrition));
      _itemDescController.clear();
      _macros.clear();
      _status = 'Added $desc. Add another, or log the meal.';
    });
  }

  Future<void> _onLogMeal() async {
    if (_items.isEmpty) {
      setState(() => _status = 'Add at least one item first.');
      return;
    }
    final name = _mealNameController.text.trim().isEmpty
        ? 'meal'
        : _mealNameController.text.trim();
    final total = mealTotal(_items);
    final components = _items.map(itemToComponent).toList();
    final slot = currentSlot(DateTime.now());
    await LogStorageService.instance.logMeal(
      name,
      total,
      slot: slot,
      components: components,
      imagePath: _imagePath,
    );
    final log = await LogStorageService.instance.readLog();
    await FoodBankService.instance.rebuildAndPersist(log);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final total = mealTotal(_items);
    return Scaffold(
      appBar: AppBar(title: const Text('Build a meal')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _mealNameController,
              decoration: const InputDecoration(
                labelText: 'Meal name (optional)',
              ),
            ),
            const SizedBox(height: 12),
            if (_items.isNotEmpty) ...[
              Text(
                'So far (${_items.length}): '
                '${_items.map((i) => i.name).join(', ')}  ->  '
                '${total.kcal.toStringAsFixed(0)} kcal  '
                'P${total.proteinG.toStringAsFixed(0)} '
                'C${total.carbsG.toStringAsFixed(0)} '
                'F${total.fatG.toStringAsFixed(0)}',
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _itemDescController,
              decoration: const InputDecoration(labelText: 'Item name'),
            ),
            const SizedBox(height: 8),
            MacroInputRow(controllers: _macros),
            const SizedBox(height: 12),
            PhotoAttachField(
              imagePath: _imagePath,
              onChanged: (path) => setState(() => _imagePath = path),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _onAddItem,
                  child: const Text('Add item'),
                ),
                ElevatedButton(
                  onPressed: _onLogMeal,
                  child: const Text('Log meal'),
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
