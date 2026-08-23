/// Single-food meal logging screen -- the app's primary, done-criterion
/// screen: "I can open the diet app on my phone and fill meal I ate."
library;

import 'dart:async';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/food_suggestion.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/screens/log_meal_actions.dart';
import 'package:diet_guard_app/screens/log_meal_kuchnia_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_nav_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_progress.dart';
import 'package:diet_guard_app/screens/log_meal_sync_mixin.dart';
import 'package:diet_guard_app/services/due_slot_check.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/autocomplete_suggestion_list.dart';
import 'package:diet_guard_app/widgets/macro_input_row.dart';
import 'package:diet_guard_app/widgets/slot_selector_row.dart';
import 'package:diet_guard_app/widgets/sync_health_banner.dart';
import 'package:diet_guard_app/widgets/today_progress_card.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Lets the user log one food item, with food-bank autocomplete and
/// today's slot status.
class LogMealScreen extends StatefulWidget {
  /// Creates a [LogMealScreen].
  const LogMealScreen({super.key, this.httpClient});

  /// Injectable HTTP client for auto-sync; tests pass a [MockClient].
  /// Production leaves this null so [GitHubClient] builds a real one.
  final http.Client? httpClient;

  @override
  State<LogMealScreen> createState() => _LogMealScreenState();
}

class _LogMealScreenState extends State<LogMealScreen>
    with
        WidgetsBindingObserver,
        LogMealSyncMixin<LogMealScreen>,
        LogMealNavMixin<LogMealScreen>,
        LogMealKuchniaMixin<LogMealScreen> {
  @override
  http.Client? get syncHttpClient => widget.httpClient;

  final TextEditingController _descController = TextEditingController();
  final MacroControllers _macros = MacroControllers();
  List<FoodSuggestion> _suggestions = const [];
  @override
  int? selectedSlot;
  String _source = 'manual';
  String? _status;
  TodayProgress? _progress;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _descController.addListener(_onDescChanged);
    for (final controller in [
      _macros.kcal,
      _macros.protein,
      _macros.carbs,
      _macros.fat,
      _macros.perGrams,
      _macros.grams,
    ]) {
      controller.addListener(_onMacroEdited);
    }
    selectedSlot = slotForLog(DateTime.now(), MealScheduleService.current);
    unawaited(refreshSlots());
    unawaited(_onDescChanged());
    // Read health before the first sync finishes, so a device that stalled in
    // a previous session says so immediately rather than only after a tick.
    unawaited(refreshSyncHealth());
    unawaited(autoSync());
    // After autoSync so a dish already logged on the PC is known before the
    // queue is built, and guarded so this costs at most one walk per day.
    unawaited(loadTodaysDelivery());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _descController.dispose();
    _macros.dispose();
    super.dispose();
  }

  void _onMacroEdited() {
    if (_source == 'food bank') {
      setState(() => _source = 'manual');
    }
  }

  /// Re-runs the food-bank search and dismisses the previous progress card.
  ///
  /// The card is cleared only when the field is non-empty because
  /// [_onLogMeal]'s own `clear()` fires this listener too: without the guard
  /// the two async chains race and the clear can null the card right after
  /// [_onLogMeal] set it, so it never appears on device (in-memory test
  /// stores resolve fast enough to hide this).
  Future<void> _onDescChanged() async {
    final matches = await FoodBankService.instance.search(_descController.text);
    if (!mounted) return;
    setState(() {
      _suggestions = matches;
      if (_descController.text.isNotEmpty) _progress = null;
    });
  }

  @override
  TextEditingController get descController => _descController;
  @override
  MacroControllers get macroControllers => _macros;
  @override
  void onDishPrefilled() => setState(() => _source = 'catering');

  void _onSuggestionSelected(FoodSuggestion suggestion) {
    _descController.text = suggestion.name;
    _macros.fillFrom(suggestion.nutrition);
    setState(() {
      _source = 'food bank';
      _suggestions = const [];
    });
  }

  Future<void> _onLogMeal() async {
    final desc = _descController.text.trim();
    if (desc.isEmpty) {
      setState(() {
        _status = 'Type what you ate first.';
        _progress = null;
      });
      return;
    }
    final nutrition = nutritionFromControllers(_macros, _source);
    await LogStorageService.instance.logMeal(
      desc,
      nutrition,
      slot: selectedSlot,
    );
    final log = await LogStorageService.instance.readLog();
    await FoodBankService.instance.rebuildAndPersist(log);
    // Push the new meal now instead of waiting for the next lifecycle event,
    // so the PC gate can see it in seconds. Fire-and-forget and best-effort:
    // autoSync is single-flight and swallows offline/transient failures.
    unawaited(autoSync());
    // Offline backstop: if the push above fails (no connectivity), a
    // connectivity-gated WorkManager task uploads the meal on reconnect.
    unawaited(enqueueSyncBackstopTask());
    // Clears a reminder the meal just logged has now satisfied; without it a
    // notification already on screen survives up to 15 min and reads as a
    // false alarm. `pullWhenDue: false` because `autoSync` above already owns
    // the network for this submit.
    await checkAndNotify(pullWhenDue: false);
    if (!mounted) return;
    _descController.clear();
    _macros.clear();
    setState(() {
      _source = 'manual';
      selectedSlot = slotForLog(DateTime.now(), MealScheduleService.current);
    });
    await refreshSlots();
    if (!mounted) return;
    // The second `prefillNextDish` caller. Without it every dish after the
    // first stays queued behind another tap and the "N more to log" line
    // becomes a dead letter -- the exact regression the PC gate once shipped.
    advanceQueueAfterLog(desc);
    setState(() {
      _status = queueStatusLine;
      _progress = buildTodayProgress(log);
    });
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diet Guard'),
        actions: [
          ...logMealAppBarActions(
            onFoodBank: onOpenFoodBank,
            onHistory: onOpenHistory,
            onCalendar: onOpenCalendar,
            onSettings: onOpenSettings,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SyncHealthBanner(status: syncHealth),
            SlotSelectorRow(
              now: DateTime.now(),
              loggedSlots: loggedSlots,
              selectedSlot: selectedSlot,
              onSlotSelected: (slot) => setState(() => selectedSlot = slot),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _descController,
              decoration: const InputDecoration(labelText: 'What did you eat?'),
            ),
            AutocompleteSuggestionList(
              suggestions: _suggestions,
              onSelected: _onSuggestionSelected,
              compact: true,
            ),
            const SizedBox(height: 8),
            MacroInputRow(controllers: _macros, compact: true),
            const SizedBox(height: 8),
            Row(
              children: [
                const Spacer(),
                Tooltip(
                  message: 'Log meal',
                  child: FilledButton(
                    onPressed: _onLogMeal,
                    child: const Icon(Icons.check_circle),
                  ),
                ),
              ],
            ),
            // Mutually exclusive: _status carries a validation complaint,
            // _progress the post-log summary. A successful log clears one
            // and sets the other, so the two never stack.
            if (_status != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(_status!),
            ],
            if (_progress != null) ...[
              const SizedBox(height: AppSpacing.sm),
              TodayProgressCard(progress: _progress!),
            ],
          ],
        ),
      ),
    );
  }
}
