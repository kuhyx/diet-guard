/// Budget-adherence calendar, streaks, year-to-date tally, budget editing.
///
/// Mirrors the diet_guard gate's calendar tab (`_gatelock_calendar.py`): the
/// budget field starts read-only, defaulting to
/// [AppSettingsService.dailyKcalGoal]'s built-in 2200 kcal fallback when
/// nothing has ever been saved, and an "Edit"/"Save" toggle button unlocks
/// it for editing on the first click and validates+persists on the second.
library;

import 'dart:async';

import 'package:diet_guard_app/models/day_status.dart';
import 'package:diet_guard_app/screens/history_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/day_status_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/widgets/day_status_calendar.dart';
import 'package:diet_guard_app/widgets/streak_summary_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Screen showing the budget-adherence calendar, streaks, and budget entry.
class CalendarScreen extends StatefulWidget {
  /// Creates a [CalendarScreen].
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  final _budgetController = TextEditingController();
  DateTime _month = DateTime.now();
  Map<String, DayStatus> _statusByDate = {};
  int _loggingStreak = 0;
  int _adherenceStreak = 0;
  YtdTally _tally = const YtdTally(
    loggedDays: 0,
    elapsedDays: 0,
    adherentDays: 0,
  );
  bool _loading = true;
  bool _editingBudget = false;
  String? _budgetStatus;
  bool _budgetError = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _budgetController.dispose();
    super.dispose();
  }

  /// Loads the log, recomputes status/streaks/tally against the current
  /// budget, and refreshes the (read-only) budget field -- unless the user
  /// is mid-edit, in which case their unsaved text is left untouched.
  Future<void> _load() async {
    final log = await LogStorageService.instance.readLog();
    if (!mounted) return;
    final budget = AppSettingsService.dailyKcalGoal;
    final statusByDate = statusMap(log, budget: budget);
    setState(() {
      _statusByDate = statusByDate;
      _loggingStreak = loggingStreak(statusByDate);
      _adherenceStreak = adherenceStreak(statusByDate);
      _tally = yearToDateTally(statusByDate);
      _loading = false;
      if (!_editingBudget) {
        _budgetController.text = budget.toString();
      }
    });
  }

  void _onPrevMonth() {
    setState(() => _month = DateTime(_month.year, _month.month - 1));
  }

  void _onNextMonth() {
    setState(() => _month = DateTime(_month.year, _month.month + 1));
  }

  /// Opens [HistoryScreen] pre-filtered to the tapped day.
  void _onDaySelected(DateTime day) {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => HistoryScreen(
            initialDateRange: DateTimeRange(start: day, end: day),
          ),
        ),
      ),
    );
  }

  /// First click: unlocks the entry for typing, relabels the button "Save".
  /// Second click: validates and persists; a validation failure leaves
  /// editing open so the user can correct the value instead of silently
  /// discarding it.
  Future<void> _onEditOrSaveBudget() async {
    if (!_editingBudget) {
      setState(() {
        _editingBudget = true;
        _budgetStatus = null;
        _budgetError = false;
      });
      return;
    }
    final value = int.tryParse(_budgetController.text.trim());
    if (value == null) {
      setState(() {
        _budgetStatus = 'Enter a whole number of kcal.';
        _budgetError = true;
      });
      return;
    }
    if (value <= 0) {
      setState(() {
        _budgetStatus = 'Budget must be a positive number.';
        _budgetError = true;
      });
      return;
    }
    await AppSettingsService.instance.saveDailyKcalGoal(value);
    if (!mounted) return;
    setState(() {
      _editingBudget = false;
      _budgetStatus = 'Saved.';
      _budgetError = false;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Calendar')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _BudgetRow(
              controller: _budgetController,
              editing: _editingBudget,
              onEditOrSave: _onEditOrSaveBudget,
            ),
            if (_budgetStatus != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _budgetStatus!,
                  style: TextStyle(
                    color: _budgetError ? theme.colorScheme.error : null,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            DayStatusCalendar(
              statusByDate: _statusByDate,
              month: _month,
              today: DateTime.now(),
              onPrevMonth: _onPrevMonth,
              onNextMonth: _onNextMonth,
              onDaySelected: _onDaySelected,
            ),
            const SizedBox(height: 16),
            StreakSummaryRow(
              loggingStreak: _loggingStreak,
              adherenceStreak: _adherenceStreak,
              tally: _tally,
            ),
          ],
        ),
      ),
    );
  }
}

class _BudgetRow extends StatelessWidget {
  const _BudgetRow({
    required this.controller,
    required this.editing,
    required this.onEditOrSave,
  });

  final TextEditingController controller;
  final bool editing;
  final VoidCallback onEditOrSave;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('Daily budget (kcal):'),
        const SizedBox(width: 8),
        SizedBox(
          width: 90,
          child: TextField(
            controller: controller,
            enabled: editing,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: onEditOrSave,
          child: Text(editing ? 'Save' : 'Edit'),
        ),
      ],
    );
  }
}
