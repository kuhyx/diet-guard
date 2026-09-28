/// BMI, ideal-weight and BMR cards -- read-only views of `body_calc.dart`.
library;

import 'package:diet_guard_app/services/body_calc.dart';
import 'package:diet_guard_app/widgets/body/body_section.dart';
import 'package:flutter/material.dart';

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
    final normal = report.category == 'normal';
    return BodySection(
      title: 'BMI',
      children: [
        BodyStatRow(
          'BMI',
          oneDecimal(report.bmi),
          color: normal ? null : Theme.of(context).colorScheme.error,
        ),
        BodyStatRow('Category', report.category),
        BodyStatRow('BMI Prime', halfUp(report.prime, 2).toStringAsFixed(2)),
        BodyStatRow('Trefethen (new BMI)', oneDecimal(report.trefethen)),
        BodyStatRow(
          'Healthy weight for your height (BMI 18.5-24.9)',
          '${oneDecimal(low)}-${oneDecimal(high)} kg',
        ),
        const BodyNote(bmiPrimeNote),
        const BodyNote(trefethenNote),
      ],
    );
  }
}

/// Every ideal-weight formula; `n/a` where one is undefined.
class IdealWeightCard extends StatelessWidget {
  /// Creates the card for [bio].
  const IdealWeightCard({required this.bio, super.key});

  /// The person.
  final Biometrics bio;

  @override
  Widget build(BuildContext context) {
    final formulas = idealWeights(bio);
    final undefined = formulas.any((f) => f.value == null);
    final summary = idealSummary(formulas);
    return BodySection(
      title: 'Ideal weight',
      children: [
        for (final formula in formulas)
          BodyStatRow(formula.name, formatKg(formula.value)),
        if (summary != null) ...[
          const Divider(),
          BodyStatRow('Average of all', formatKg(summary.$1)),
          BodyStatRow(
            'Ideal range',
            '${oneDecimal(summary.$2)}-${oneDecimal(summary.$3)} kg',
          ),
        ],
        const BodyNote(brocaNote),
        if (undefined)
          const BodyNote(
            'Devine, Robinson, Miller and Hamwi are undefined below 152.4 cm.',
          ),
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
      title: 'Resting metabolism (BMR)',
      children: [
        for (final formula in bmrFormulas(bio, bodyFatPct))
          BodyStatRow(
            formula.name,
            formula.value == null
                ? 'n/a -- log a body-fat %'
                : '${whole(formula.value!)} kcal',
          ),
      ],
    );
  }
}
