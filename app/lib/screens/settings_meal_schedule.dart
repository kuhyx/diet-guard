// The meal-schedule editor: first meal, last meal, how many meals, and a
// live preview of the checkpoint times they derive.
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

  /// The meal counts selectable for the current window.
  ///
  /// Capped at the number of whole hours the window holds, so the count
  /// dropdown can never offer a value that would round two meals onto the
  /// same hour. Invalid states are made unrepresentable here rather than
  /// validated after the fact -- `MealSchedule.normalized` still clamps, but
  /// that is the defence against corrupt synced data, not the input contract.
  List<int> get _selectableCounts {
    final span = _schedule.last - _schedule.first;
    final maxCount = span + 1 < kMaxMealCount ? span + 1 : kMaxMealCount;
    return [for (var n = kMinMealCount; n <= maxCount; n++) n];
  }

  Future<void> _applySchedule(MealSchedule next) async {
    final normalized = next.normalized();
    setState(() => _schedule = normalized);
    if (!MealScheduleService.isInitialized) return;
    await MealScheduleService.instance.recordChange(normalized);
    // The reminder ids are slot hours, so a schedule change orphans the ones
    // it no longer contains. Re-running the check cancels them immediately
    // rather than leaving a stale nag until the next background tick.
    await checkAndNotify(pullWhenDue: false);
  }

  /// Dropdowns rather than a time picker: `showTimePicker` returns minutes,
  /// and slots are whole hours on both devices by design.
  Widget _hourDropdown({
    required String label,
    required int value,
    required List<int> hours,
    required ValueChanged<int> onChanged,
  }) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: AppWidth.field),
    child: InputDecorator(
      decoration: InputDecoration(labelText: label),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: value,
          isDense: true,
          isExpanded: true,
          items: [
            for (final hour in hours)
              DropdownMenuItem(value: hour, child: Text(slotLabel(hour))),
          ],
          onChanged: (hour) => hour == null ? null : onChanged(hour),
        ),
      ),
    ),
  );

  List<Widget> _mealScheduleSection(BuildContext context) {
    final theme = Theme.of(context);
    final counts = _selectableCounts;
    return [
      Text('Meal times', style: theme.textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(
        'Checkpoints are spread evenly between your first and last meal.',
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 12),
      _hourDropdown(
        label: 'First meal',
        value: _schedule.first,
        // Leaves at least one hour of window, so `last` always has a value
        // strictly after `first` to offer.
        hours: [for (var h = kFirstHour; h < kLastHour; h++) h],
        onChanged: (hour) => unawaited(
          _applySchedule(
            MealSchedule(
              first: hour,
              last: _schedule.last,
              count: _schedule.count,
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      _hourDropdown(
        label: 'Last meal',
        value: _schedule.last,
        hours: [for (var h = _schedule.first + 1; h <= kLastHour; h++) h],
        onChanged: (hour) => unawaited(
          _applySchedule(
            MealSchedule(
              first: _schedule.first,
              last: hour,
              count: _schedule.count,
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppWidth.field),
        child: InputDecorator(
          decoration: const InputDecoration(labelText: 'Meals per day'),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: counts.contains(_schedule.count)
                  ? _schedule.count
                  : counts.last,
              isDense: true,
              isExpanded: true,
              items: [
                for (final count in counts)
                  DropdownMenuItem(value: count, child: Text('$count')),
              ],
              onChanged: (count) => count == null
                  ? null
                  : unawaited(
                      _applySchedule(
                        MealSchedule(
                          first: _schedule.first,
                          last: _schedule.last,
                          count: count,
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        _schedule.slots().map(slotLabel).join('  ·  '),
        style: theme.textTheme.bodyMedium,
      ),
    ];
  }
}
