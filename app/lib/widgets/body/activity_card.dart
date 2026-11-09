/// Recent workouts the PC published, with exercise kcal per formula.
library;

import 'package:diet_guard_app/services/activity_kcal.dart';
import 'package:diet_guard_app/ui/cues.dart';
import 'package:diet_guard_app/ui/macro_kind.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/body/body_section.dart';
import 'package:diet_guard_app/widgets/body/formula_figure.dart';
import 'package:flutter/material.dart';

/// How many of the newest sessions to list.
const int activityListLimit = 10;

/// Shows the 14-day daily means and the newest sessions.
class ActivityCard extends StatelessWidget {
  /// Creates the card.
  const ActivityCard({
    required this.sessions,
    required this.weightKg,
    required this.exercise,
    this.steps = const {},
    this.stepsKcal,
    this.onConnectSteps,
    this.window = maxWindowDays,
    super.key,
  });

  /// How many full past days [exercise] averages (see `windowDays`).
  final int window;

  /// Published sessions, or null when the PC never published any.
  final List<Session>? sessions;

  /// Weight used for the kcal formulas, or null when unknown.
  final double? weightKg;

  /// The 14-day daily means per formula (steps included), or null.
  final Map<String, double>? exercise;

  /// Steps outside workouts by day.
  final Map<String, int> steps;

  /// Mean daily net kcal of the counted steps alone, or null.
  final double? stepsKcal;

  /// Asks for the Health Connect permission; null hides the button (not
  /// supported here, or already granted).
  final VoidCallback? onConnectSteps;

  @override
  Widget build(BuildContext context) {
    final list = sessions ?? const <Session>[];
    final kg = weightKg;
    final means = exercise;
    final newest = [...list]..sort((a, b) => b.day.compareTo(a.day));
    final stepKcal = stepsKcal;
    final lastDay = steps.isEmpty
        ? null
        : steps.keys.reduce((a, b) => a.compareTo(b) > 0 ? a : b);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return BodySection(
      semanticLabel: 'Activity',
      children: [
        if (sessions == null && steps.isEmpty)
          const StatusCue(
            kind: CueKind.info,
            icon: Icons.directions_run,
            semanticLabel: 'No activity data yet -- published by the PC.',
          ),
        if (means != null) ...[
          Row(
            children: [
              Icon(
                Icons.date_range,
                size: 18,
                color: muted,
                semanticLabel: 'Mean daily exercise, last $window full days:',
              ),
              const SizedBox(width: AppSpacing.xs),
              Text('$window'),
            ],
          ),
          for (final name in activityFormulas)
            _FormulaRow(name, whole(means[name] ?? 0)),
        ],
        if (lastDay != null && stepKcal != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(
              children: [
                Icon(
                  Icons.directions_walk,
                  size: 18,
                  color: muted,
                  semanticLabel: 'Steps outside workouts',
                ),
                const SizedBox(width: AppSpacing.xs),
                Text('${steps[lastDay]}  $lastDay'),
                const Spacer(),
                Icon(Icons.add, size: 16, color: muted),
                MacroFigure(
                  kind: MacroKind.kcal,
                  value: whole(stepKcal),
                  size: 16,
                ),
              ],
            ),
          ),
        if (onConnectSteps != null)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: onConnectSteps,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.directions_walk,
                    semanticLabel: 'Connect Health Connect steps',
                  ),
                  Icon(Icons.link),
                ],
              ),
            ),
          ),
        if (sessions != null && kg == null)
          const StatusCue(
            kind: CueKind.warn,
            icon: Icons.monitor_weight,
            semanticLabel: 'Enter your weight to estimate exercise kcal.',
          ),
        if (sessions != null && kg != null) ...[
          const Divider(),
          if (newest.isEmpty)
            const StatusCue(
              kind: CueKind.info,
              icon: Icons.event_busy,
              semanticLabel: 'No workouts in the last 28 days.',
            ),
          for (final session in newest.take(activityListLimit))
            _SessionTile(result: sessionKcal(session, kg)),
        ],
      ],
    );
  }
}

/// A formula's glyph on the left, its kcal figure on the right.
class _FormulaRow extends StatelessWidget {
  const _FormulaRow(this.name, this.value);

  final String name;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs / 2),
    child: Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: FormulaGlyph(name),
          ),
        ),
        MacroFigure(kind: MacroKind.kcal, value: value, size: 16),
      ],
    ),
  );
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.result});

  final SessionKcal result;

  @override
  Widget build(BuildContext context) {
    final session = result.session;
    final km = session.km;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${session.day}  ${session.label}'),
          Row(
            children: [
              Icon(
                Icons.timer_outlined,
                size: 16,
                color: muted,
                semanticLabel: 'minutes',
              ),
              Text(' ${whole(session.minutes)}'),
              if (km != null) ...[
                const SizedBox(width: AppSpacing.md),
                Icon(Icons.route, size: 16, color: muted, semanticLabel: 'km'),
                Text(' ${oneDecimal(km)}'),
              ],
              const SizedBox(width: AppSpacing.md),
              Icon(
                MacroKind.kcal.icon,
                size: 16,
                color: MacroKind.kcal.color,
                semanticLabel: 'kcal',
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Wrap(
                  spacing: AppSpacing.sm,
                  children: [
                    for (final name in activityFormulas)
                      FormulaFigure(
                        name,
                        whole(result.kcal[name]!),
                        fallback: result.fallback.contains(name),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
