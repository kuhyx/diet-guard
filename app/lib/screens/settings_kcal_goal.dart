// The debounced daily-kcal-goal field and the battery-exemption request.
//
// Split out of `settings_screen.dart` for the repo's 250-line cap. A `part`
// mixin: these drive the screen's private state and call `setState`, which is
// `@protected` and therefore unreachable from an extension.

part of 'settings_screen.dart';

mixin _SettingsKcalGoal on State<SettingsScreen> {
  String? _status;

  void _showMessage(String message) {
    if (!mounted) return;
    setState(() => _status = message);
  }

  Timer? _kcalGoalDebounce;
  int? _pendingKcalGoal;

  /// Persists the pending goal, if any, and clears it.
  void _flushKcalGoal() {
    final goal = _pendingKcalGoal;
    if (goal == null) return;
    _pendingKcalGoal = null;
    unawaited(AppSettingsService.instance.saveDailyKcalGoal(goal));
  }

  /// Saves the typed goal once typing settles.
  ///
  /// Debounced because every keystroke would otherwise be a real edit:
  /// typing "2000" saved 2, 20, 200, 2000 in turn, and a sync tick landing
  /// between keystrokes would push a nonsense budget to the other device.
  void _onKcalGoalChanged(String value) {
    _kcalGoalDebounce?.cancel();
    final goal = int.tryParse(value);
    if (goal == null || goal <= 0) return;
    _pendingKcalGoal = goal;
    _kcalGoalDebounce = Timer(
      const Duration(milliseconds: 600),
      _flushKcalGoal,
    );
  }

  /// Requests exemption from OEM battery optimization (MIUI, some Samsung
  /// configs), which can otherwise degrade the 15-minute background-check
  /// reliability well past its accepted ±15 min target.
  Future<void> _requestBatteryExemption() async {
    final request =
        widget.requestBatteryExemption ??
        () => Permission.ignoreBatteryOptimizations.request();
    try {
      final status = await request();
      _showMessage(
        status.isGranted
            ? 'Battery optimization exemption granted.'
            : 'Exemption not granted -- notifications may be delayed.',
      );
    } on Exception catch (e) {
      _showMessage('Could not request exemption: $e');
    }
  }
}
