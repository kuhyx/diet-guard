/// Single-food meal logging screen -- the app's primary, done-criterion
/// screen: "I can open the diet app on my phone and fill meal I ate."
library;

import 'dart:async';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/food_suggestion.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/screens/calendar_screen.dart';
import 'package:diet_guard_app/screens/food_bank_screen.dart';
import 'package:diet_guard_app/screens/history_screen.dart';
import 'package:diet_guard_app/screens/meal_builder_screen.dart';
import 'package:diet_guard_app/screens/settings_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/background_tasks.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/github_client_factory.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/sync_service.dart';
import 'package:diet_guard_app/services/sync_settings.dart';
import 'package:diet_guard_app/widgets/autocomplete_suggestion_list.dart';
import 'package:diet_guard_app/widgets/macro_input_row.dart';
import 'package:diet_guard_app/widgets/photo_attach_field.dart';
import 'package:diet_guard_app/widgets/slot_selector_row.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// Lets the user log one food item, with food-bank autocomplete and
/// today's slot status, or hop into [MealBuilderScreen] for a composite
/// multi-item meal.
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
    with WidgetsBindingObserver {
  final TextEditingController _descController = TextEditingController();
  final MacroControllers _macros = MacroControllers();
  List<FoodSuggestion> _suggestions = const [];
  Set<int> _loggedSlots = {};
  int? _selectedSlot;
  String _source = 'manual';
  String? _status;
  String? _imagePath;
  FoodEntry? _lastEntry;
  bool _showRewardPrompt = false;

  /// Single-flight guard so a launch sync and a lifecycle sync never overlap.
  bool _autoSyncing = false;

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
    _selectedSlot = currentSlot(DateTime.now());
    unawaited(_refreshSlots());
    unawaited(_onDescChanged());
    unawaited(_autoSync());
    unawaited(_refreshLastEntry());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _descController.dispose();
    _macros.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pull on resume (catch up on what another device logged while this one
    // was backgrounded) and push on pause (keep the remote near-current).
    final isResumeOrPause =
        state == AppLifecycleState.resumed || state == AppLifecycleState.paused;
    if (isResumeOrPause) {
      unawaited(_autoSync());
    }
  }

  /// Best-effort background sync: silent, skips when unconfigured, and never
  /// overlaps itself. Failures are swallowed -- the Settings screen's manual
  /// "Sync now" is where errors get surfaced. The try wraps even loading
  /// [SyncSettings] itself: under `flutter test`, the shared_preferences and
  /// secure-storage platform channels are unmocked by default and throw
  /// [MissingPluginException], which must degrade exactly like "offline"
  /// rather than crash every screen that mounts this widget.
  ///
  /// [_refreshSlots] only runs after an actual sync (not on the unconfigured
  /// path, which every existing screen test takes): a fire-and-forget tail
  /// await here can resolve after a *later* test's `tearDown` has already
  /// reset [LogStorageService]'s singleton -- `mounted` alone doesn't bound
  /// that, since widget disposal between tests isn't synchronized with a
  /// still-pending Future from an earlier one.
  Future<void> _autoSync() async {
    if (_autoSyncing) return;
    _autoSyncing = true;
    try {
      final settings = await SyncSettings.load();
      if (!settings.isConfigured) return;
      final client = createGitHubClient(
        settings,
        httpClient: widget.httpClient,
      );
      try {
        await runSync(client);
      } finally {
        client.close();
      }
      if (!mounted) return;
      await _refreshSlots();
    } on Exception {
      // Best-effort: ignore (offline, transient GitHub errors, unmocked
      // platform channels under test, etc.).
    } finally {
      _autoSyncing = false;
    }
  }

  /// Queues the platform's offline push backstop so a meal logged while
  /// offline still uploads on reconnect. The in-process [_autoSync] covers
  /// the online case; this is the backstop (a no-op on web, which has no
  /// out-of-page scheduler -- see background_tasks.dart).
  // coverage:ignore-start
  Future<void> _enqueueSyncBackstop() => enqueueSyncBackstop();

  // coverage:ignore-end

  Future<void> _refreshSlots() async {
    final logged = await LogStorageService.instance.loggedSlotsToday();
    if (!mounted) return;
    setState(() => _loggedSlots = logged);
  }

  /// Refreshes the entry "repeat last meal" would log, and its enabled
  /// state. Called after every log (manual, built, or repeated) so the
  /// button always repeats the most recent entry, not a stale one.
  Future<void> _refreshLastEntry() async {
    final entry = await LogStorageService.instance.lastLoggedEntry();
    if (!mounted) return;
    setState(() => _lastEntry = entry);
  }

  void _onMacroEdited() {
    if (_source == 'food bank') {
      setState(() => _source = 'manual');
    }
  }

  Future<void> _onDescChanged() async {
    final matches = await FoodBankService.instance.search(
      _descController.text,
    );
    if (!mounted) return;
    setState(() {
      _suggestions = matches;
      // Starting to fill in the manual form dismisses a stale reward prompt
      // left over from a prior one-tap "repeat last meal" log.
      _showRewardPrompt = false;
    });
  }

  void _onSuggestionSelected(FoodSuggestion suggestion) {
    _descController.text = suggestion.name;
    _macros.kcal.text = suggestion.nutrition.kcal.toStringAsFixed(0);
    _macros.protein.text = suggestion.nutrition.proteinG.toStringAsFixed(0);
    _macros.carbs.text = suggestion.nutrition.carbsG.toStringAsFixed(0);
    _macros.fat.text = suggestion.nutrition.fatG.toStringAsFixed(0);
    _macros.perGrams.text = suggestion.nutrition.grams.toStringAsFixed(0);
    _macros.grams.text = suggestion.nutrition.grams.toStringAsFixed(0);
    setState(() {
      _source = 'food bank';
      _suggestions = const [];
    });
  }

  double _parse(TextEditingController controller) =>
      double.tryParse(controller.text.trim()) ?? 0;

  Future<void> _onLogMeal() async {
    final desc = _descController.text.trim();
    if (desc.isEmpty) {
      setState(() => _status = 'Type what you ate first.');
      return;
    }
    final nutrition = nutritionForPortion(
      kcal: _parse(_macros.kcal),
      proteinG: _parse(_macros.protein),
      carbsG: _parse(_macros.carbs),
      fatG: _parse(_macros.fat),
      perGrams: _parse(_macros.perGrams),
      ateGrams: _parse(_macros.grams),
      source: _source,
    );
    await LogStorageService.instance.logMeal(
      desc,
      nutrition,
      slot: _selectedSlot,
      imagePath: _imagePath,
    );
    final log = await LogStorageService.instance.readLog();
    await FoodBankService.instance.rebuildAndPersist(log);
    // Push the new meal now instead of waiting for the next lifecycle event,
    // so the PC gate can see it in seconds. Fire-and-forget and best-effort:
    // _autoSync is single-flight and swallows offline/transient failures.
    unawaited(_autoSync());
    // Offline backstop: if the push above fails (no connectivity), a
    // connectivity-gated WorkManager task uploads the meal on reconnect.
    unawaited(_enqueueSyncBackstop());
    if (!mounted) return;
    _descController.clear();
    _macros.clear();
    setState(() {
      _source = 'manual';
      _imagePath = null;
      _selectedSlot = currentSlot(DateTime.now());
    });
    await _refreshSlots();
    if (!mounted) return;
    setState(() => _status = 'Logged "$desc".');
    await _refreshLastEntry();
  }

  /// One-tap "repeat last meal": re-logs [_lastEntry] verbatim (minus any
  /// photo) against today's current slot. Mirrors [_onLogMeal]'s post-write
  /// sequence exactly so offline/sync semantics stay identical.
  Future<void> _onLogLastMeal() async {
    final last = _lastEntry;
    if (last == null) return;
    final nutrition = Nutrition(
      kcal: last.kcal,
      proteinG: last.proteinG,
      carbsG: last.carbsG,
      fatG: last.fatG,
      grams: last.grams,
      source: last.source,
    );
    await LogStorageService.instance.logMeal(
      last.desc,
      nutrition,
      slot: currentSlot(DateTime.now()),
      components: last.components,
      // No imagePath: a repeated meal shouldn't drag forward a photo of a
      // specific past occasion.
    );
    final log = await LogStorageService.instance.readLog();
    await FoodBankService.instance.rebuildAndPersist(log);
    unawaited(_autoSync());
    unawaited(_enqueueSyncBackstop());
    if (!mounted) return;
    await _refreshSlots();
    if (!mounted) return;
    setState(() {
      _status = 'Logged "${last.desc}" again.';
      _showRewardPrompt = AppSettingsService.rewardUrl?.isNotEmpty ?? false;
    });
    await _refreshLastEntry();
  }

  Future<void> _openReward() async {
    final url = AppSettingsService.rewardUrl;
    if (url == null || url.isEmpty) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Future<void> _onBuildMeal() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const MealBuilderScreen()),
    );
    await _refreshSlots();
    await _refreshLastEntry();
    // A meal built and logged in the builder should push right away too,
    // with the same offline backstop.
    unawaited(_autoSync());
    unawaited(_enqueueSyncBackstop());
  }

  void _onOpenHistory() {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => const HistoryScreen()),
      ),
    );
  }

  void _onOpenCalendar() {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => const CalendarScreen()),
      ),
    );
  }

  void _onOpenFoodBank() {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => const FoodBankScreen()),
      ),
    );
  }

  void _onOpenSettings() {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => SettingsScreen(httpClient: widget.httpClient),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diet Guard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.restaurant_menu),
            tooltip: 'Food bank',
            onPressed: _onOpenFoodBank,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'History',
            onPressed: _onOpenHistory,
          ),
          IconButton(
            icon: const Icon(Icons.calendar_month),
            tooltip: 'Calendar',
            onPressed: _onOpenCalendar,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Sync settings',
            onPressed: _onOpenSettings,
          ),
        ],
      ),
      floatingActionButton: Tooltip(
        message: _lastEntry == null
            ? 'No previous meal to repeat'
            : 'Repeat "${_lastEntry!.desc}"',
        child: FloatingActionButton.extended(
          onPressed: _lastEntry == null ? null : _onLogLastMeal,
          icon: const Icon(Icons.repeat),
          label: const Text('Repeat last meal'),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SlotSelectorRow(
              now: DateTime.now(),
              loggedSlots: _loggedSlots,
              selectedSlot: _selectedSlot,
              onSlotSelected: (slot) => setState(() => _selectedSlot = slot),
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
                PhotoAttachField(
                  imagePath: _imagePath,
                  onChanged: (path) => setState(() => _imagePath = path),
                  compact: true,
                ),
                const Spacer(),
                Tooltip(
                  message: 'Build a multi-item meal',
                  child: OutlinedButton(
                    onPressed: _onBuildMeal,
                    child: const Icon(Icons.playlist_add),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Log meal',
                  child: FilledButton(
                    onPressed: _onLogMeal,
                    child: const Icon(Icons.check_circle),
                  ),
                ),
              ],
            ),
            if (_status != null) ...[
              const SizedBox(height: 12),
              Text(_status!),
            ],
            if (_showRewardPrompt &&
                (AppSettingsService.rewardUrl?.isNotEmpty ?? false)) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => unawaited(_openReward()),
                icon: const Icon(Icons.card_giftcard),
                label: Text(
                  'Open ${AppSettingsService.rewardLabel ?? "reward"}',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
