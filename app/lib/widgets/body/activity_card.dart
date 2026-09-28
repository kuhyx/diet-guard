/// Recent workouts the PC published, with exercise kcal per formula.
library;

import 'package:diet_guard_app/services/activity_kcal.dart';
import 'package:diet_guard_app/services/body_steps.dart';
import 'package:diet_guard_app/widgets/body/body_section.dart';
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
    return BodySection(
      title: 'Activity',
      children: [
        if (sessions == null && steps.isEmpty)
          const BodyNote('No activity data yet -- published by the PC.'),
        if (means != null) ...[
          BodyNote('Mean daily exercise, last $window full days:'),
          for (final name in activityFormulas)
            BodyStatRow(name, '${whole(means[name] ?? 0)} kcal/day'),
        ],
        if (lastDay != null && stepKcal != null)
          BodyNote(
            'Steps outside workouts: ${steps[lastDay]} on $lastDay; above '
            '$stepBaseline/day they add ${whole(stepKcal)} kcal/day '
            '(included above).',
          ),
        if (onConnectSteps != null)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.directions_walk),
              label: const Text('Connect Health Connect steps'),
              onPressed: onConnectSteps,
            ),
          ),
        if (sessions != null && kg == null)
          const BodyNote('Enter your weight to estimate exercise kcal.'),
        if (sessions != null && kg != null) ...[
          const Divider(),
          if (newest.isEmpty)
            const BodyNote('No workouts in the last 28 days.'),
          for (final session in newest.take(activityListLimit))
            _SessionTile(result: sessionKcal(session, kg)),
          if (newest.isNotEmpty)
            const BodyNote('~ = no distance, MET estimate used instead.'),
          const BodyNote(methodsNote),
        ],
      ],
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.result});

  final SessionKcal result;

  @override
  Widget build(BuildContext context) {
    final session = result.session;
    final km = session.km;
    final distance = km == null ? '' : ', ${oneDecimal(km)} km';
    final kcal = [
      for (final name in activityFormulas)
        _formulaKcal(name, result.kcal[name]!, result.fallback.contains(name)),
    ].join(' · ');
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text('${session.day}  ${session.label}'),
      subtitle: Text(
        '${whole(session.minutes)} min$distance\n$kcal kcal',
      ),
      isThreeLine: true,
    );
  }
}

String _formulaKcal(String name, double kcal, bool fallback) =>
    '$name ${whole(kcal)}${fallback ? '~' : ''}';
