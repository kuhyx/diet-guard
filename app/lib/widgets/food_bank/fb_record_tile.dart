/// The full-detail row for one banked food, shown in the tile's sheet.
library;

import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/ui/macro_kind.dart';
import 'package:flutter/material.dart';

/// One banked food: its name, macros, and how often it has been logged.
///
/// Macros are glyph + number pairs; the reference weight carries the scale
/// glyph, the use count keeps its `×N` numeral.
class RecordTile extends StatelessWidget {
  /// Creates a [RecordTile] for [record].
  const RecordTile(this.record, {super.key});

  /// The banked record this tile renders.
  final FoodBankRecord record;

  @override
  Widget build(BuildContext context) {
    String n(double v) => v.toStringAsFixed(0);
    return ListTile(
      title: Text(record.desc),
      subtitle: Wrap(
        spacing: 12,
        children: [
          MacroFigure(kind: MacroKind.kcal, value: n(record.kcal)),
          if (record.grams > 0)
            MacroFigure(kind: MacroKind.perGrams, value: '${n(record.grams)}g'),
          MacroFigure(kind: MacroKind.protein, value: '${n(record.proteinG)}g'),
          MacroFigure(kind: MacroKind.carbs, value: '${n(record.carbsG)}g'),
          MacroFigure(kind: MacroKind.fat, value: '${n(record.fatG)}g'),
        ],
      ),
      trailing: record.count > 0
          ? Text(
              '×${n(record.count)}',
              style: Theme.of(context).textTheme.bodySmall,
            )
          : null,
    );
  }
}
