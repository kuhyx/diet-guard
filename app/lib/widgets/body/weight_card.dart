/// Dated-value entry (any day, save or delete) with its history chart.
///
/// One widget serves both logs -- weight and body fat -- so the two cards
/// cannot drift apart; [WeightCard] and [BodyFatCard] only configure it.
library;

import 'package:diet_guard_app/models/body_document.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/widgets/body/dated_value_card.dart';
import 'package:flutter/material.dart';

export 'package:diet_guard_app/widgets/body/dated_value_card.dart';

/// Weight: 20-400 kg; wake-alarm weigh-ins land here too.
class WeightCard extends StatelessWidget {
  /// Creates the card.
  const WeightCard({required this.onChanged, super.key});

  /// Called once a value has been written or deleted.
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final body = BodyService.instance;
    return DatedValueCard(
      semanticLabel: 'Weight',
      fieldSemanticLabel: 'Weight (kg)',
      icon: Icons.monitor_weight,
      unit: 'kg',
      min: 20,
      max: 400,
      latest: body.latestWeight,
      series: body.weightSeries,
      onSave: body.setWeight,
      onDelete: body.deleteWeight,
      onChanged: onChanged,
    );
  }
}

/// Body fat: 3-70 %; the newest reading switches the table to Katch-McArdle.
class BodyFatCard extends StatelessWidget {
  /// Creates the card.
  const BodyFatCard({required this.onChanged, super.key});

  /// Called once a value has been written or deleted.
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final body = BodyService.instance;
    return DatedValueCard(
      semanticLabel: 'Body fat',
      fieldSemanticLabel: 'Body fat (%)',
      icon: Icons.percent,
      unit: '%',
      min: minBodyFat,
      max: maxBodyFat,
      latest: body.latestBodyFat,
      series: body.bodyFatSeries,
      onSave: body.setBodyFat,
      onDelete: body.deleteBodyFat,
      onChanged: onChanged,
    );
  }
}
