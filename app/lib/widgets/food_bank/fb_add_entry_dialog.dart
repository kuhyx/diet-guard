/// The "add a manual food bank entry" dialog.
///
/// Split out of `food_bank_screen.dart` for the repo's 250-line cap.
library;

import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/ui/cues.dart';
import 'package:diet_guard_app/ui/macro_kind.dart';
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

  Widget _field(MacroKind kind, TextEditingController ctrl) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: IconField(
      icon: kind.icon,
      iconColor: kind.color,
      semanticLabel: kind.semanticLabel(compact: false),
      controller: ctrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      dense: true,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: IconField(
                icon: Icons.restaurant,
                semanticLabel: 'Name',
                controller: _name,
                dense: true,
              ),
            ),
            _field(MacroKind.perGrams, _grams),
            _field(MacroKind.kcal, _kcal),
            _field(MacroKind.protein, _protein),
            _field(MacroKind.carbs, _carbs),
            _field(MacroKind.fat, _fat),
          ],
        ),
      ),
      actions: [
        IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close, semanticLabel: 'Cancel'),
        ),
        ElevatedButton(
          onPressed: _save,
          child: const Icon(Icons.check, semanticLabel: 'Save to bank'),
        ),
      ],
    );
  }
}
