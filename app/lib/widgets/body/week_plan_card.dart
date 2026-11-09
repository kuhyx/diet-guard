/// Weekly-average planner: "I ate N on day X -- what now for the rest?"
///
/// Info only. Past days fill in from the food log; typing a number for any
/// day overrides it (a planned feast on Saturday too).
library;

import 'package:diet_guard_app/services/body_energy.dart';
import 'package:diet_guard_app/services/week_plan.dart';
import 'package:diet_guard_app/ui/cues.dart';
import 'package:diet_guard_app/ui/macro_kind.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/body/body_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The planner.
class WeekPlanCard extends StatefulWidget {
  /// Creates the card.
  const WeekPlanCard({
    required this.defaultTarget,
    required this.logged,
    this.today,
    super.key,
  });

  /// The average to aim for until the user types one (the daily budget).
  final int defaultTarget;

  /// `YYYY-MM-DD` -> kcal eaten, from the food log.
  final Map<String, double> logged;

  /// Overrides "today" for tests.
  final DateTime? today;

  @override
  State<WeekPlanCard> createState() => _WeekPlanCardState();
}

class _WeekPlanCardState extends State<WeekPlanCard> {
  final _target = TextEditingController();
  final List<TextEditingController> _days = List.generate(
    7,
    (_) => TextEditingController(),
  );

  @override
  void dispose() {
    _target.dispose();
    for (final controller in _days) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final target = int.tryParse(_target.text) ?? widget.defaultTarget;
    final typed = <int, int>{
      for (var i = 0; i < 7; i++) i: ?int.tryParse(_days[i].text),
    };
    final plan = planWeek(
      widget.today ?? DateTime.now(),
      target,
      widget.logged,
      typed,
    );
    final scheme = Theme.of(context).colorScheme;
    return BodySection(
      semanticLabel: 'Week planner',
      children: [
        SpokenLabel(
          semanticLabel: 'Weekly average target (kcal/day)',
          child: TextField(
            controller: _target,
            decoration: InputDecoration(
              prefixIcon: ExcludeSemantics(
                child: Icon(MacroKind.kcal.icon, color: MacroKind.kcal.color),
              ),
              hintText: '${widget.defaultTarget}',
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        for (var i = 0; i < 7; i++)
          Row(
            children: [
              // Day of month, not a weekday word: rows run Monday..Sunday.
              SizedBox(width: 32, child: Text(plan.days[i].day.substring(8))),
              Expanded(
                child: _DayFigure(plan.days[i], belowFloor: plan.belowFloor),
              ),
              SizedBox(
                width: 96,
                child: IconField(
                  icon: Icons.rice_bowl,
                  semanticLabel: 'ate…',
                  controller: _days[i],
                  dense: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
        const SizedBox(height: AppSpacing.sm),
        _Summary(plan, scheme),
      ],
    );
  }
}

/// A day's kcal with a glyph for where the number came from.
class _DayFigure extends StatelessWidget {
  const _DayFigure(this.day, {required this.belowFloor});

  final DayPlan day;
  final bool belowFloor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, spoken) = switch (day.source) {
      'typed' => (Icons.edit, '(typed)'),
      'logged' => (Icons.check, '(logged)'),
      'unlogged' => (Icons.help_outline, '(not logged -- type it)'),
      _ => (Icons.insights, '(plan)'),
    };
    final bad = day.source == 'plan' && belowFloor;
    final unlogged = day.source == 'unlogged';
    final tint = bad
        ? scheme.error
        : unlogged
        ? CueKind.warn.tint(context)
        : null;
    return Row(
      children: [
        MacroFigure(kind: MacroKind.kcal, value: '${day.kcal}', size: 16),
        const SizedBox(width: AppSpacing.sm),
        Icon(icon, size: 16, color: tint, semanticLabel: spoken),
      ],
    );
  }
}

/// What to eat on the open days, or the finished week's average.
class _Summary extends StatelessWidget {
  const _Summary(this.plan, this.scheme);

  final WeekPlan plan;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final per = plan.perRemaining;
    if (per == null) {
      return Row(
        children: [
          Icon(
            Icons.check_circle,
            color: CueKind.ok.tint(context),
            semanticLabel: 'Every day is known: week average',
          ),
          const SizedBox(width: AppSpacing.xs),
          MacroFigure(kind: MacroKind.kcal, value: whole(plan.weekAvg)),
        ],
      );
    }
    return Row(
      children: [
        const Icon(Icons.restaurant, size: 18, semanticLabel: 'Eat'),
        const SizedBox(width: AppSpacing.xs),
        MacroFigure(kind: MacroKind.kcal, value: '$per'),
        const SizedBox(width: AppSpacing.md),
        const Icon(Icons.flag_outlined, size: 18, semanticLabel: 'average'),
        const SizedBox(width: AppSpacing.xs),
        Text('${plan.targetAvg}'),
        if (plan.belowFloor) ...[
          const SizedBox(width: AppSpacing.md),
          const StatusCue(
            kind: CueKind.error,
            icon: Icons.vertical_align_bottom,
            semanticLabel: 'below the $minTargetKcal kcal floor',
          ),
        ],
      ],
    );
  }
}
