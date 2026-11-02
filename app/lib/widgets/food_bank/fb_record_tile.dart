/// The full-detail row for one banked food, shown in the tile's sheet.
library;

import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:flutter/material.dart';

/// One banked food: its name, macros, and how often it has been logged.
class RecordTile extends StatelessWidget {
  /// Creates a [RecordTile] for [record].
  const RecordTile(this.record, {super.key});

  /// The banked record this tile renders.
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
      subtitle: Text('${record.kcal.toStringAsFixed(0)} kcal$per  ·  $macros'),
      trailing: record.count > 0
          ? Text(
              '×${record.count.toStringAsFixed(0)}',
              style: Theme.of(context).textTheme.bodySmall,
            )
          : null,
    );
  }
}
