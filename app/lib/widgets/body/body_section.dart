/// A titled card, the building block of every Body screen section.
library;

import 'package:diet_guard_app/services/body_calc.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// A card with a title row and [children] stacked below it.
class BodySection extends StatelessWidget {
  /// Creates a section.
  const BodySection({
    required this.title,
    required this.children,
    super.key,
  });

  /// Section heading.
  final String title;

  /// Section content.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// A label on the left, a value on the right; one line of a stats card.
class BodyStatRow extends StatelessWidget {
  /// Creates a row.
  const BodyStatRow(this.label, this.value, {this.color, super.key});

  /// What the value is.
  final String label;

  /// The formatted value.
  final String value;

  /// Optional value color (e.g. a warning).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs / 2),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// A muted one-line explanation (missing data, notes).
class BodyNote extends StatelessWidget {
  /// Creates a note.
  const BodyNote(this.text, {super.key});

  /// The note.
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// `74.99` -> `"75.0 kg"`, null -> `"n/a"`. Half-up, like the PC.
String formatKg(double? kg) => kg == null ? 'n/a' : '${oneDecimal(kg)} kg';

/// [value] to one decimal, rounded half-up like the PC prints it.
String oneDecimal(double value) => halfUp(value, 1).toStringAsFixed(1);

/// [value] as a whole number, rounded half-up like the PC prints it.
String whole(double value) => halfUp(value).toInt().toString();
