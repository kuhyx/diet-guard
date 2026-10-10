// The meal-schedule section: owns the schedule state and its persistence;
// the widgets themselves live in `widgets/meal_schedule_editor.dart`.
//
// Split out of `settings_screen.dart` for the repo's 250-line cap. A `part`
// mixin for the same reason as `_SettingsKcalGoal`: it drives the screen's
// private state and calls `setState`.

part of 'settings_screen.dart';

mixin _SettingsMealSchedule on State<SettingsScreen> {
  MealSchedule _schedule = kDefaultSchedule;

  void _loadSchedule() {
    _schedule = MealScheduleService.current;
  }

  Future<void> _applySchedule(MealSchedule next) async {
    final normalized = next.normalized();
    setState(() => _schedule = normalized);
    if (!MealScheduleService.isInitialized) return;
    await MealScheduleService.instance.recordChange(normalized);
    // The reminder ids are slot minutes, so a schedule change leaves posted
    // reminders for checkpoints that no longer exist. Re-running the check
    // cancels them immediately rather than leaving a stale nag until the
    // next background tick.
    await checkAndNotify(pullWhenDue: false);
  }

  List<Widget> _mealScheduleSection(BuildContext context) => [
    MealScheduleEditor(
      schedule: _schedule,
      onChanged: (next) => unawaited(_applySchedule(next)),
    ),
  ];
}
