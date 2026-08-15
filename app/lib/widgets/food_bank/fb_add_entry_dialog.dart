/// The "add a manual food bank entry" dialog.
///
/// Split out of `food_bank_screen.dart` for the repo's 250-line cap.
library;

import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:flutter/material.dart';

/// Prompts for a new manually-curated food bank entry.
///
/// Pops with the new [FoodBankRecord], or null when cancelled.
class AddEntryDialog extends StatefulWidget {
  /// Creates an [AddEntryDialog] with empty fields.
  const AddEntryDialog({super.key});

  @override
  State<AddEntryDialog> createState() => AddEntryDialogState();
}

/// State for [AddEntryDialog], owning its text controllers.
class AddEntryDialogState extends State<AddEntryDialog> {
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
