/// A row of macro entry fields (kcal/protein/carbs/fat/grams), with an
/// optional reference weight so a label's per-100g macros can be typed
/// directly and scaled to the amount actually eaten.
library;

import 'package:flutter/material.dart';

/// Text controllers for one macro-entry row, owned by the calling screen so
/// it can read/clear/prefill values around the row's lifecycle.
class MacroControllers {
  /// Creates a fresh set of empty macro controllers.
  MacroControllers()
    : kcal = TextEditingController(),
      protein = TextEditingController(),
      carbs = TextEditingController(),
      fat = TextEditingController(),
      perGrams = TextEditingController(),
      grams = TextEditingController();

  /// Calories controller.
  final TextEditingController kcal;

  /// Protein (g) controller.
  final TextEditingController protein;

  /// Carbohydrate (g) controller.
  final TextEditingController carbs;

  /// Fat (g) controller.
  final TextEditingController fat;

  /// Reference weight (g) the typed macros are stated for, e.g. `100` for
  /// a per-100g label. Blank means the macros already describe the full
  /// eaten portion.
  final TextEditingController perGrams;

  /// Portion weight actually eaten (g). Blank assumes the eaten amount
  /// equals [perGrams].
  final TextEditingController grams;

  /// Clears every field's text.
  void clear() {
    kcal.clear();
    protein.clear();
    carbs.clear();
    fat.clear();
    perGrams.clear();
    grams.clear();
  }

  /// Disposes every controller.
  void dispose() {
    kcal.dispose();
    protein.dispose();
    carbs.dispose();
    fat.dispose();
    perGrams.dispose();
    grams.dispose();
  }
}

/// A labeled row of number-entry fields for calories, macros, and the
/// optional reference-weight-vs-eaten-weight split.
class MacroInputRow extends StatelessWidget {
  /// Creates a [MacroInputRow] bound to [controllers].
  const MacroInputRow({required this.controllers, super.key});

  /// The text controllers this row reads from and writes to.
  final MacroControllers controllers;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: _macroField('kcal', controllers.kcal)),
            const SizedBox(width: 8),
            Expanded(
              child: _macroField(
                'macros per (g)',
                controllers.perGrams,
                helperText: 'e.g. 100 for a per-100g label',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _macroField('protein g', controllers.protein)),
            const SizedBox(width: 8),
            Expanded(child: _macroField('carbs g', controllers.carbs)),
            const SizedBox(width: 8),
            Expanded(child: _macroField('fat g', controllers.fat)),
          ],
        ),
        const SizedBox(height: 8),
        _macroField(
          'amount eaten (g)',
          controllers.grams,
          helperText: "blank = same as 'macros per'",
        ),
      ],
    );
  }

  Widget _macroField(
    String label,
    TextEditingController controller, {
    String? helperText,
  }) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        isDense: true,
      ),
    );
  }
}
