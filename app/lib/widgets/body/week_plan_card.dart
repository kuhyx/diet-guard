/// Weekly-average planner: "I ate N on day X -- what now for the rest?"
///
/// Info only. Past days fill in from the food log; typing a number for any
/// day overrides it (a planned feast on Saturday too).
library;

import 'package:diet_guard_app/services/week_plan.dart';
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
      for (var i = 0; i < 7; i++)
        i: ?int.tryParse(_days[i].text),
    };
    final plan = planWeek(
      widget.today ?? DateTime.now(),
      target,
      widget.logged,
      typed,
    );
    final scheme = Theme.of(context).colorScheme;
    return BodySection(
      title: 'Week planner (info only)',
      children: [
        TextField(
          controller: _target,
          decoration: InputDecoration(
            labelText: 'Weekly average target (kcal/day)',
            hintText: '${widget.defaultTarget}',
          ),
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: AppSpacing.sm),
        for (var i = 0; i < 7; i++)
          Row(
            children: [
              SizedBox(width: 48, child: Text(plan.days[i].weekday)),
              Expanded(
                child: Text(
                  '${plan.days[i].kcal} kcal  ${_sourceLabel(plan.days[i])}',
                  style: TextStyle(
                    color: plan.days[i].source == 'plan' && plan.belowFloor
                        ? scheme.error
                        : null,
                  ),
                ),
              ),
              SizedBox(
                width: 96,
                child: TextField(
                  controller: _days[i],
                  decoration: const InputDecoration(
                    hintText: 'ate…',
                    isDense: true,
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
        const SizedBox(height: AppSpacing.sm),
        BodyNote(_summary(plan)),
      ],
    );
  }
}

String _sourceLabel(DayPlan day) => switch (day.source) {
  'typed' => '(typed)',
  'logged' => '(logged)',
  'unlogged' => '(not logged -- type it)',
  _ => '(plan)',
};

String _summary(WeekPlan plan) {
  final per = plan.perRemaining;
  if (per == null) {
    return 'Every day is known: week average '
        '${whole(plan.weekAvg)} kcal.';
  }
  final floor = plan.belowFloor ? ' -- below the 1200 kcal floor!' : '';
  return 'Eat $per kcal on each open day to average '
      '${plan.targetAvg}$floor';
}
