/// The Body screen's top line as marks instead of a sentence: direction
/// arrow, amount, unit, per-period calendar, activity glyph, then a bolt and
/// the daily kcal answer. Every mark is tappable and opens a picker; the
/// choice is saved (and synced) immediately. Informational only.
library;

import 'dart:async';

import 'package:diet_guard_app/services/body_calc.dart';
import 'package:diet_guard_app/services/body_energy.dart';
import 'package:diet_guard_app/services/body_prefs.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/ui/cues.dart';
import 'package:diet_guard_app/ui/macro_kind.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/body/body_section.dart';
import 'package:diet_guard_app/widgets/body/goal_icons.dart';
import 'package:diet_guard_app/widgets/body/goal_pickers.dart';
import 'package:flutter/material.dart';

/// The goal row and its answer.
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

  /// A bordered, tappable mark spoken as [spoken]; [child] is its look.
  Widget _choice(
    String spoken,
    Widget child,
    Future<Goal?> Function(BuildContext, Goal) picker,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: spoken,
      child: InkWell(
        onTap: () => unawaited(_pick(picker)),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: scheme.outline),
          ),
          child: ExcludeSemantics(
            child: DefaultTextStyle.merge(
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
              child: IconTheme.merge(
                data: IconThemeData(color: scheme.primary),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconChoice(
    String spoken,
    IconData icon,
    Future<Goal?> Function(BuildContext, Goal) picker, {
    String? caption,
  }) => _choice(
    spoken,
    Row(
      mainAxisSize: MainAxisSize.min,
      children: [Icon(icon), if (caption != null) Text(caption)],
    ),
    picker,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bmr = tableBmr(widget.bio, widget.bodyFatPct);
    final target = goalTarget(_goal, bmr.value!, bmr.name, widget.exercise);
    final kcal = target.kcal;
    final tdee = target.tdee;
    final maintain = _goal.direction == 'maintain';
    return BodySection(
      semanticLabel: 'Daily calorie target',
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            _iconChoice(
              _goal.direction,
              directionIcon(_goal.direction),
              pickDirection,
            ),
            if (!maintain) ...[
              _choice(
                formatG(_goal.amount),
                Text(formatG(_goal.amount)),
                pickAmount,
              ),
              _choice(_goal.weightUnit, Text(_goal.weightUnit), pickWeightUnit),
              _iconChoice(
                _goal.timeUnit,
                timeUnitIcon(_goal.timeUnit),
                pickTimeUnit,
              ),
            ],
            _iconChoice(
              activityLabel(_goal.activity),
              activityIcon(_goal.activity),
              pickActivity,
              caption: activityCaption(_goal.activity),
            ),
            if (kcal != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(MacroKind.kcal.icon, color: theme.colorScheme.primary),
                  Text(
                    '$kcal',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        if (kcal == null)
          const StatusCue(
            kind: CueKind.warn,
            icon: Icons.directions_run,
            semanticLabel: 'no workouts published yet (the PC publishes them).',
          ),
        if (target.belowFloor)
          const StatusCue(
            kind: CueKind.error,
            icon: Icons.vertical_align_bottom,
            semanticLabel: 'That is below the $minTargetKcal kcal floor.',
          ),
        if (tdee != null)
          Row(
            children: [
              Icon(
                Icons.balance,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
                semanticLabel: 'Maintenance',
              ),
              const SizedBox(width: AppSpacing.xs),
              MacroFigure(kind: MacroKind.kcal, value: whole(tdee), size: 16),
              const SizedBox(width: AppSpacing.sm),
              Text(target.bmrName),
            ],
          ),
      ],
    );
  }
}
