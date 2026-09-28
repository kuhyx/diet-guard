/// The Body screen's top line: "To [lose] [0.5] [kg] / [week] on
/// [Moderate] eat 2019 kcal". Every bracket is tappable and opens a picker;
/// the choice is saved (and synced) immediately. Informational only.
library;

import 'dart:async';

import 'package:diet_guard_app/services/body_calc.dart';
import 'package:diet_guard_app/services/body_energy.dart';
import 'package:diet_guard_app/services/body_prefs.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/body/body_section.dart';
import 'package:diet_guard_app/widgets/body/goal_pickers.dart';
import 'package:flutter/material.dart';

/// The goal sentence and its answer.
class GoalCard extends StatefulWidget {
  /// Creates the card.
  const GoalCard({
    required this.bio,
    this.exercise,
    this.bodyFatPct,
    super.key,
  });

  /// The person.
  final Biometrics bio;

  /// Mean daily net exercise per formula (steps included), or null.
  final Map<String, double>? exercise;

  /// The newest body fat %, which switches the base BMR, or null.
  final double? bodyFatPct;

  @override
  State<GoalCard> createState() => _GoalCardState();
}

class _GoalCardState extends State<GoalCard> {
  late Goal _goal = savedGoal(BodyService.instance);

  Future<void> _pick(Future<Goal?> Function(BuildContext, Goal) picker) async {
    final picked = await picker(context, _goal);
    if (picked == null || !mounted) return;
    setState(() => _goal = picked);
    await setGoal(BodyService.instance, picked);
  }

  Widget _choice(String text, Future<Goal?> Function(BuildContext, Goal) p) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => unawaited(_pick(p)),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
        child: Text(
          text,
          style: TextStyle(
            color: scheme.primary,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.underline,
            decorationColor: scheme.primary,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bmr = tableBmr(widget.bio, widget.bodyFatPct);
    final target = goalTarget(_goal, bmr.value!, bmr.name, widget.exercise);
    final kcal = target.kcal;
    final tdee = target.tdee;
    final maintain = _goal.direction == 'maintain';
    return BodySection(
      title: 'Daily calorie target',
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: AppSpacing.xs,
          children: [
            const Text('To'),
            _choice(_goal.direction, pickDirection),
            if (!maintain) ...[
              _choice(formatG(_goal.amount), pickAmount),
              _choice(_goal.weightUnit, pickWeightUnit),
              const Text('/'),
              _choice(_goal.timeUnit, pickTimeUnit),
            ],
            const Text('on'),
            _choice(activityLabel(_goal.activity), pickActivity),
            if (kcal != null) ...[
              const Text('eat '),
              Text(
                '$kcal',
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Text(' kcal'),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        if (kcal == null)
          const BodyNote('no workouts published yet (the PC publishes them).'),
        if (target.belowFloor)
          Text(
            'That is below the $minTargetKcal kcal floor.',
            style: TextStyle(color: theme.colorScheme.error),
          ),
        if (tdee != null)
          BodyNote(
            'Maintenance ${whole(tdee)} kcal (${target.bmrName} resting '
            'burn x activity); 1 kg of fat = ${formatG(kcalPerKg)} kcal.',
          ),
        const BodyNote(
          'Informational only — the budget is never changed from here.',
        ),
      ],
    );
  }
}
