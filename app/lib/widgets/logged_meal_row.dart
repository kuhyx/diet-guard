/// One meal the screen logged for the user: where it came from, what it is,
/// and a plain round undo.
library;

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/ui/macro_kind.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:material_ui/material_ui.dart';

/// How the entry got logged; picks the leading glyph.
enum LoggedOrigin {
  /// Claude read the text and/or photo (sparkle).
  claude,

  /// The delivered catering dish logged itself (restaurant).
  catering,

  /// The check button (check).
  local,
}

/// A logged meal and the way it got logged.
@immutable
class LoggedMeal {
  /// Creates the pair.
  const LoggedMeal(this.entry, this.origin);

  /// The entry that was written.
  final FoodEntry entry;

  /// How it got logged.
  final LoggedOrigin origin;
}

/// Name, kcal and macro figures, and an undo button (no countdown).
class LoggedMealRow extends StatelessWidget {
  /// Creates the row.
  const LoggedMealRow({required this.meal, required this.onUndo, super.key});

  /// The meal shown.
  final LoggedMeal meal;

  /// Tombstones the entry.
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = meal.entry;
    final (icon, color) = switch (meal.origin) {
      LoggedOrigin.claude => (Icons.auto_awesome, theme.colorScheme.primary),
      LoggedOrigin.catering => (
        Icons.restaurant,
        theme.colorScheme.onSurfaceVariant,
      ),
      LoggedOrigin.local => (
        Icons.check_circle,
        (theme.extension<AppStatusColors>() ?? AppStatusColors.dark).success,
      ),
    };
    String n(double v) => v.round().toString();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.desc, maxLines: 1, overflow: TextOverflow.ellipsis),
                Wrap(
                  spacing: AppSpacing.sm,
                  children: [
                    MacroFigure(
                      kind: MacroKind.kcal,
                      value: n(entry.kcal),
                      size: 16,
                    ),
                    MacroFigure(
                      kind: MacroKind.protein,
                      value: n(entry.proteinG),
                    ),
                    MacroFigure(kind: MacroKind.carbs, value: n(entry.carbsG)),
                    MacroFigure(kind: MacroKind.fat, value: n(entry.fatG)),
                  ],
                ),
              ],
            ),
          ),
          IconButton.filledTonal(
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            onPressed: onUndo,
            icon: const Icon(Icons.undo, semanticLabel: 'Undo'),
          ),
        ],
      ),
    );
  }
}
