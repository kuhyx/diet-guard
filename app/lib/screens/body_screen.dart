/// The Body screen: the goal sentence first, then weight (+ graph), BMI,
/// ideal weight, BMR, measured activity and steps, the week planner, the
/// profile (at the top instead while incomplete), and body fat last.
///
/// The phone half of the PC gate's Body tab (`_gatelock_body*.py`), reading
/// the same synced `body.json` (see `docs/DOCS-body.md`). **Informational
/// only**: nothing here writes the daily budget -- there is deliberately no
/// "apply" button.
library;

import 'dart:async';

import 'package:diet_guard_app/services/activity_kcal.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/body_calc.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/services/body_steps.dart';
import 'package:diet_guard_app/services/health_steps.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/body/activity_card.dart';
import 'package:diet_guard_app/widgets/body/body_section.dart';
import 'package:diet_guard_app/widgets/body/body_stats_cards.dart';
import 'package:diet_guard_app/widgets/body/goal_card.dart';
import 'package:diet_guard_app/widgets/body/profile_card.dart';
import 'package:diet_guard_app/widgets/body/week_plan_card.dart';
import 'package:diet_guard_app/widgets/body/weight_card.dart';
import 'package:flutter/material.dart';

/// Builds the person from the stored profile and newest weight, or null
/// when anything the formulas need is missing.
Biometrics? currentBiometrics(BodyService body, DateTime today) {
  final birth = DateTime.tryParse(body.birth ?? '');
  final height = body.heightCm;
  final sex = body.sex;
  final weight = body.latestWeight;
  if (birth == null || height == null || sex == null || weight == null) {
    return null;
  }
  return Biometrics(
    weightKg: weight.$2,
    heightCm: height,
    ageYears: ageOn(birth, today).toDouble(),
    isMale: sex == 'm',
  );
}

/// Steps outside workouts by day, as stored.
Map<String, int> stepsByDay(BodyService body) =>
    body.document.steps.map((day, entry) => MapEntry(day, entry.n));

/// Mean daily exercise per formula (steps included), the steps' own share,
/// and the number of full days averaged -- like the PC's `_body_view`: the
/// two means are null without a person, or without any published workout
/// or step count.
(Map<String, double>?, double?, int) bodyExercise(
  BodyService body,
  Biometrics? bio,
  DateTime today,
) {
  final sessions = body.sessions;
  final steps = stepsByDay(body);
  if (bio == null || (sessions == null && steps.isEmpty)) {
    return (null, null, 0);
  }
  final byDay = steps.map((day, n) => MapEntry(day, stepKcal(n, bio)));
  final weight = bio.weightKg;
  final all = sessions ?? const <Session>[];
  return (
    dailyExercise(all, weight, today, byDay),
    extraShare(all, today, byDay),
    windowDays(all, today, byDay),
  );
}

/// Sums each day's non-deleted kcal.
Map<String, double> kcalByDay(DayLog log) => {
  for (final entry in log.entries)
    entry.key: entry.value
        .where((food) => !food.deleted)
        .fold<double>(0, (sum, food) => sum + food.kcal),
};

/// The Body screen.
class BodyScreen extends StatefulWidget {
  /// Creates the screen.
  const BodyScreen({super.key});

  @override
  State<BodyScreen> createState() => _BodyScreenState();
}

class _BodyScreenState extends State<BodyScreen> {
  Map<String, double> _logged = const {};

  /// Decided once, when the screen opens: a complete profile sits at the
  /// bottom, an incomplete one at the top. Re-deciding on every build would
  /// yank the card away mid-edit the moment the last field is saved; it
  /// moves the next time the screen is entered.
  late final bool _profileAtTop = !BodyService.instance.profileComplete;

  /// Whether the Health Connect button shows: supported and not yet granted.
  bool _canConnectSteps = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLog());
    unawaited(_loadSteps());
  }

  /// Refreshes steps (only when already permitted -- never prompts) and
  /// decides whether to offer the connect button.
  Future<void> _loadSteps() async {
    final source = stepsSource;
    if (!source.supported) return;
    final granted = await source.hasPermission().catchError((_) => false);
    if (granted) await refreshSteps();
    if (!mounted) return;
    setState(() => _canConnectSteps = !granted);
  }

  Future<void> _connectSteps() async {
    final granted = await stepsSource.requestPermission().catchError(
      (_) => false,
    );
    if (granted) await refreshSteps();
    if (!mounted) return;
    setState(() => _canConnectSteps = !granted);
  }

  Future<void> _loadLog() async {
    final log = await LogStorageService.instance.readLog();
    if (!mounted) return;
    setState(() => _logged = kcalByDay(log));
  }

  /// Any profile/weight write changes every derived card; the cards read
  /// [BodyService] in `build`, so a rebuild is all they need.
  void _onChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final body = BodyService.instance;
    final today = DateTime.now();
    final bio = currentBiometrics(body, today);
    final sessions = body.sessions;
    final weight = body.latestWeight?.$2;
    final (exercise, stepsKcal, window) = bodyExercise(body, bio, today);
    final bodyFat = body.latestBodyFat?.$2;
    final profile = ProfileCard(onSaved: _onChanged);
    return Scaffold(
      appBar: AppBar(title: const Text('Body')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppWidth.prose),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_profileAtTop) profile,
                if (bio == null)
                  BodySection(
                    title: 'Daily calorie target',
                    children: [BodyNote(_missing(body))],
                  )
                else
                  GoalCard(bio: bio, exercise: exercise, bodyFatPct: bodyFat),
                WeightCard(onChanged: _onChanged),
                if (bio != null) ...[
                  BmiCard(bio: bio),
                  IdealWeightCard(bio: bio),
                  BmrCard(bio: bio, bodyFatPct: bodyFat),
                ],
                ActivityCard(
                  sessions: sessions,
                  weightKg: weight,
                  exercise: exercise,
                  steps: stepsByDay(body),
                  stepsKcal: stepsKcal,
                  window: window,
                  onConnectSteps: _canConnectSteps ? _connectSteps : null,
                ),
                WeekPlanCard(
                  defaultTarget: AppSettingsService.dailyKcalGoal,
                  logged: _logged,
                ),
                if (!_profileAtTop) profile,
                BodyFatCard(onChanged: _onChanged),
                BodyNote('Age ${_age(body, today)} · synced with the PC.'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _missing(BodyService body) {
  if (body.latestWeight == null && body.birth == null) {
    return 'Set your profile and enter your weight to see BMI, ideal '
        'weight and calorie targets.';
  }
  if (body.latestWeight == null) return 'Enter your weight to see the numbers.';
  return 'Set your profile (birth date, height, sex) to see the numbers.';
}

String _age(BodyService body, DateTime today) {
  final birth = DateTime.tryParse(body.birth ?? '');
  return birth == null ? 'unknown' : '${ageOn(birth, today)}';
}
