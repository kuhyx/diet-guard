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

import 'package:diet_guard_app/screens/body_screen_data.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/body_calc.dart';
import 'package:diet_guard_app/services/body_energy.dart';
import 'package:diet_guard_app/services/body_prefs.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/services/health_steps.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/body/activity_card.dart';
import 'package:diet_guard_app/widgets/body/body_section.dart';
import 'package:diet_guard_app/widgets/body/body_stats_cards.dart';
import 'package:diet_guard_app/widgets/body/body_tile_grid.dart';
import 'package:diet_guard_app/widgets/body/goal_card.dart';
import 'package:diet_guard_app/widgets/body/profile_card.dart';
import 'package:diet_guard_app/widgets/body/week_plan_card.dart';
import 'package:diet_guard_app/widgets/body/weight_card.dart';
import 'package:flutter/material.dart';

export 'package:diet_guard_app/screens/body_screen_data.dart';

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
  ///
  /// A notifier, not a bool: the Activity sheet stays open while the
  /// permission is granted, and its button must disappear and its numbers
  /// refresh without reopening the sheet.
  final ValueNotifier<bool> _canConnectSteps = ValueNotifier(false);

  @override
  void dispose() {
    _canConnectSteps.dispose();
    super.dispose();
  }

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
    _canConnectSteps.value = !granted;
    setState(() {});
  }

  Future<void> _connectSteps() async {
    final granted = await stepsSource.requestPermission().catchError(
      (_) => false,
    );
    if (granted) await refreshSteps();
    if (!mounted) return;
    _canConnectSteps.value = !granted;
    setState(() {});
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
    final (exercise, _, _) = bodyExercise(body, bio, today);
    final tiles = _tiles(body, bio, exercise);
    return Scaffold(
      appBar: AppBar(title: const Text('Body')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppWidth.prose),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BodyTileGrid(tiles: tiles),
                const SizedBox(height: AppSpacing.sm),
                BodyNote(
                  'Age ${bodyAgeText(body, today)} · synced with the PC.',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The Activity card from the live service state.
  Widget _activityCard({required bool canConnect}) {
    final body = BodyService.instance;
    final (exercise, stepsKcal, window) = bodyExercise(
      body,
      currentBiometrics(body, DateTime.now()),
      DateTime.now(),
    );
    return ActivityCard(
      sessions: body.sessions,
      weightKg: body.latestWeight?.$2,
      exercise: exercise,
      steps: stepsByDay(body),
      stepsKcal: stepsKcal,
      window: window,
      onConnectSteps: canConnect ? _connectSteps : null,
    );
  }

  /// Every section as a tile: the profile first while it is incomplete, last
  /// otherwise (decided once, see [_profileAtTop]).
  List<BodyTileSpec> _tiles(
    BodyService body,
    Biometrics? bio,
    Map<String, double>? exercise,
  ) {
    final weight = body.latestWeight?.$2;
    final bodyFat = body.latestBodyFat?.$2;
    final profile = BodyTileSpec(
      title: 'Profile',
      builder: (_) => ProfileCard(onSaved: _onChanged),
    );
    final goal = bio == null
        ? null
        : goalTarget(
            savedGoal(body),
            tableBmr(bio, bodyFat).value!,
            tableBmr(bio, bodyFat).name,
            exercise,
          ).kcal;
    return [
      if (_profileAtTop) profile,
      BodyTileSpec(
        title: 'Daily calorie target',
        value: goal == null ? null : '$goal kcal',
        builder: (_) => bio == null
            ? BodySection(
                title: 'Daily calorie target',
                children: [BodyNote(bodyMissingNote(body))],
              )
            : GoalCard(bio: bio, exercise: exercise, bodyFatPct: bodyFat),
      ),
      BodyTileSpec(
        title: 'Weight',
        value: weight == null ? null : formatKg(weight),
        builder: (_) => WeightCard(onChanged: _onChanged),
      ),
      if (bio != null) ...[
        BodyTileSpec(
          title: 'BMI',
          value: oneDecimal(bmiReport(bio).bmi),
          builder: (_) => BmiCard(bio: bio),
        ),
        BodyTileSpec(
          title: 'Ideal weight',
          builder: (_) => IdealWeightCard(bio: bio),
        ),
        BodyTileSpec(
          title: 'Resting metabolism (BMR)',
          value: '${whole(tableBmr(bio, bodyFat).value!)} kcal',
          builder: (_) => BmrCard(bio: bio, bodyFatPct: bodyFat),
        ),
      ],
      BodyTileSpec(
        title: 'Activity',
        builder: (_) => ValueListenableBuilder<bool>(
          valueListenable: _canConnectSteps,
          builder: (_, canConnect, _) => _activityCard(canConnect: canConnect),
        ),
      ),
      BodyTileSpec(
        title: 'Week planner (info only)',
        builder: (_) => WeekPlanCard(
          defaultTarget: AppSettingsService.dailyKcalGoal,
          logged: _logged,
        ),
      ),
      if (!_profileAtTop) profile,
      BodyTileSpec(
        title: 'Body fat',
        value: bodyFat == null ? null : '${oneDecimal(bodyFat)} %',
        builder: (_) => BodyFatCard(onChanged: _onChanged),
      ),
    ];
  }
}
