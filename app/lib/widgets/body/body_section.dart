/// A card, the building block of every Body screen section, plus the
/// icon-led stat rows the cards are made of. No headings: the overview tile
/// that opened the sheet already says what it is.
library;

import 'package:diet_guard_app/services/body_calc.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// A card with [children] stacked in it; [semanticLabel] names it for screen
/// readers and tests and is never painted.
class BodySection extends StatelessWidget {
  /// Creates a section.
  const BodySection({
    required this.semanticLabel,
    required this.children,
    super.key,
  });

  /// Spoken name of the section.
  final String semanticLabel;

  /// Section content.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: semanticLabel,
      child: Card(
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// One line of a stats card: a leading mark on the left, a value on the right.
///
/// The mark is either a formula name ([BodyStatRow.named]: a proper noun such
/// as Devine or ACSM, shown as is) or an icon ([BodyStatRow.icon]).
class BodyStatRow extends StatelessWidget {
  /// A row led by a formula's proper name.
  const BodyStatRow.named(this.name, this.value, {this.color, super.key})
    : icon = null,
      semanticLabel = null;

  /// A row led by [icon], spoken as [semanticLabel].
  const BodyStatRow.icon(
    IconData this.icon,
    String this.semanticLabel,
    this.value, {
    this.color,
    super.key,
  }) : name = null;

  /// Proper-noun lead, or null when an icon leads.
  final String? name;

  /// Icon lead, or null when a name leads.
  final IconData? icon;

  /// Spoken description of [icon].
  final String? semanticLabel;

  /// The formatted value.
  final String value;

  /// Optional value color (e.g. a warning).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final lead = icon;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs / 2),
      child: Row(
        children: [
          Expanded(
            child: lead == null
                ? Text(name!)
                : Align(
                    alignment: Alignment.centerLeft,
                    child: Icon(lead, size: 20, semanticLabel: semanticLabel),
                  ),
          ),
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

/// `74.99` -> `"75.0 kg"`, null -> a dash. Half-up, like the PC.
String formatKg(double? kg) => kg == null ? '—' : '${oneDecimal(kg)} kg';

/// [value] to one decimal, rounded half-up like the PC prints it.
String oneDecimal(double value) => halfUp(value, 1).toStringAsFixed(1);

/// [value] as a whole number, rounded half-up like the PC prints it.
String whole(double value) => halfUp(value).toInt().toString();
