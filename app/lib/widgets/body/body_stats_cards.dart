/// BMI, ideal-weight and BMR cards -- read-only views of `body_calc.dart`.
library;

import 'package:diet_guard_app/services/body_calc.dart';
import 'package:diet_guard_app/ui/cues.dart';
import 'package:diet_guard_app/ui/macro_kind.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/body/body_section.dart';
import 'package:flutter/material.dart';

/// The BMI band as glyph + colour (never colour alone): a green check inside
/// the healthy range, an amber or red arrow towards the side it is off by.
(IconData, CueKind) bmiBandCue(String category) {
  if (category == 'normal') return (Icons.check_circle, CueKind.ok);
  if (category.contains('thinness')) {
    return (Icons.trending_down, CueKind.warn);
  }
  if (category.startsWith('overweight')) {
    return (Icons.trending_up, CueKind.warn);
  }
  if (category.startsWith('obese')) return (Icons.trending_up, CueKind.error);
  return (Icons.help_outline, CueKind.info);
}

/// BMI, BMI Prime, Trefethen's BMI and the WHO category.
class BmiCard extends StatelessWidget {
  /// Creates the card for [bio].
  const BmiCard({required this.bio, super.key});

  /// The person.
  final Biometrics bio;

  @override
  Widget build(BuildContext context) {
    final report = bmiReport(bio);
    final (low, high) = healthyRange(bio);
    final (icon, kind) = bmiBandCue(report.category);
    final tint = kind.tint(context);
    return BodySection(
      semanticLabel: 'BMI',
      children: [
        Row(
          children: [
            Icon(icon, color: tint, semanticLabel: report.category),
            const SizedBox(width: AppSpacing.sm),
            Text(
              oneDecimal(report.bmi),
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(color: tint),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        BodyStatRow.named(
          'BMI Prime',
          halfUp(report.prime, 2).toStringAsFixed(2),
        ),
        BodyStatRow.named('Trefethen', oneDecimal(report.trefethen)),
        BodyStatRow.icon(
          Icons.favorite,
          'Healthy weight for your height (BMI 18.5-24.9)',
          '${oneDecimal(low)}-${oneDecimal(high)} kg',
        ),
      ],
    );
  }
}

/// Every ideal-weight formula; a dash where one is undefined.
class IdealWeightCard extends StatelessWidget {
  /// Creates the card for [bio].
  const IdealWeightCard({required this.bio, super.key});

  /// The person.
  final Biometrics bio;

  @override
  Widget build(BuildContext context) {
    final formulas = idealWeights(bio);
    final summary = idealSummary(formulas);
    return BodySection(
      semanticLabel: 'Ideal weight',
      children: [
        for (final formula in formulas)
          BodyStatRow.named(formula.name, formatKg(formula.value)),
        if (summary != null) ...[
          const Divider(),
          BodyStatRow.icon(
            Icons.functions,
            'Average of all',
            formatKg(summary.$1),
          ),
          BodyStatRow.icon(
            Icons.swap_horiz,
            'Ideal range',
            '${oneDecimal(summary.$2)}-${oneDecimal(summary.$3)} kg',
          ),
        ],
      ],
    );
  }
}

/// Resting metabolic rate by every formula; lean-mass ones need body fat.
class BmrCard extends StatelessWidget {
  /// Creates the card for [bio].
  const BmrCard({required this.bio, this.bodyFatPct, super.key});

  /// The person.
  final Biometrics bio;

  /// The newest body fat %, or null.
  final double? bodyFatPct;

  @override
  Widget build(BuildContext context) {
    return BodySection(
      semanticLabel: 'Resting metabolism (BMR)',
      children: [
        for (final formula in bmrFormulas(bio, bodyFatPct))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs / 2),
            child: Row(
              children: [
                Expanded(child: Text(formula.name)),
                if (formula.value == null)
                  Icon(
                    Icons.percent,
                    size: 18,
                    color: CueKind.warn.tint(context),
                    semanticLabel: 'n/a -- log a body-fat %',
                  )
                else
                  MacroFigure(
                    kind: MacroKind.kcal,
                    value: whole(formula.value!),
                    size: 16,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
