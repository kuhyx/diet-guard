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
///
/// Layout mirrors the Python gate's macro section: the reference weight
/// (`per (g)`) sits on the same line as `kcal` so the user can see at a
/// glance which portion size the calories describe.
class MacroInputRow extends StatelessWidget {
  /// Creates a [MacroInputRow] bound to [controllers].
  ///
  /// When [compact] is true, all six fields render in a single row with
  /// abbreviated labels instead of the default three stacked rows.
  const MacroInputRow({
    required this.controllers,
    this.compact = false,
    super.key,
  });

  /// The text controllers this row reads from and writes to.
  final MacroControllers controllers;

  /// Whether to render all fields in one row with abbreviated labels.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Row(
        children: [
          Expanded(child: _macroField('per', controllers.perGrams)),
          const SizedBox(width: 4),
          Expanded(child: _macroField('kcal', controllers.kcal)),
          const SizedBox(width: 4),
          Expanded(child: _macroField('P', controllers.protein)),
          const SizedBox(width: 4),
          Expanded(child: _macroField('C', controllers.carbs)),
          const SizedBox(width: 4),
          Expanded(child: _macroField('F', controllers.fat)),
          const SizedBox(width: 4),
          Expanded(
            child: Tooltip(
              message: "blank = same as 'per (g)'",
              child: _macroField('eaten', controllers.grams),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // per-gram reference weight and kcal on the same line.
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            SizedBox(
              width: 72,
              child: _macroField('per (g)', controllers.perGrams),
            ),
            const SizedBox(width: 8),
            Expanded(child: _macroField('kcal', controllers.kcal)),
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
          'eaten (g)',
          controllers.grams,
          helperText: "blank = same as 'per (g)'",
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
