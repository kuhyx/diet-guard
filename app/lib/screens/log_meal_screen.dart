/// Single-food meal logging screen -- the app's primary, done-criterion
/// screen: "I can open the diet app on my phone and fill meal I ate."
library;

import 'dart:async';

import 'package:diet_guard_app/models/food_suggestion.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/screens/history_screen.dart';
import 'package:diet_guard_app/screens/meal_builder_screen.dart';
import 'package:diet_guard_app/screens/settings_screen.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/github_client.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/sync_service.dart';
import 'package:diet_guard_app/services/sync_settings.dart';
import 'package:diet_guard_app/widgets/autocomplete_suggestion_list.dart';
import 'package:diet_guard_app/widgets/macro_input_row.dart';
import 'package:diet_guard_app/widgets/photo_attach_field.dart';
import 'package:diet_guard_app/widgets/slot_status_bar.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

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
  String _source = 'manual';
  String? _status;
  String? _imagePath;

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
    unawaited(_refreshSlots());
    unawaited(_onDescChanged());
    unawaited(_autoSync());
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
      final client = GitHubClient(
        owner: settings.owner,
        repo: settings.repo,
        token: settings.token,
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

  Future<void> _refreshSlots() async {
    final logged = await LogStorageService.instance.loggedSlotsToday();
    if (!mounted) return;
    setState(() => _loggedSlots = logged);
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
    setState(() => _suggestions = matches);
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
    final slot = currentSlot(DateTime.now());
    await LogStorageService.instance.logMeal(
      desc,
      nutrition,
      slot: slot,
      imagePath: _imagePath,
    );
    final log = await LogStorageService.instance.readLog();
    await FoodBankService.instance.rebuildAndPersist(log);
    if (!mounted) return;
    _descController.clear();
    _macros.clear();
    setState(() {
      _source = 'manual';
      _imagePath = null;
    });
    await _refreshSlots();
    if (!mounted) return;
    setState(() => _status = 'Logged "$desc".');
  }

  Future<void> _onBuildMeal() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const MealBuilderScreen()),
    );
    await _refreshSlots();
  }

  void _onOpenHistory() {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => const HistoryScreen()),
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
            icon: const Icon(Icons.history),
            tooltip: 'History',
            onPressed: _onOpenHistory,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Sync settings',
            onPressed: _onOpenSettings,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SlotStatusBar(now: DateTime.now(), loggedSlots: _loggedSlots),
            const SizedBox(height: 16),
            TextField(
              controller: _descController,
              decoration: const InputDecoration(labelText: 'What did you eat?'),
            ),
            AutocompleteSuggestionList(
              suggestions: _suggestions,
              onSelected: _onSuggestionSelected,
            ),
            const SizedBox(height: 12),
            MacroInputRow(controllers: _macros),
            const SizedBox(height: 12),
            PhotoAttachField(
              imagePath: _imagePath,
              onChanged: (path) => setState(() => _imagePath = path),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _onLogMeal,
                  child: const Text('Log meal'),
                ),
                OutlinedButton(
                  onPressed: _onBuildMeal,
                  child: const Text('Build a multi-item meal'),
                ),
              ],
            ),
            if (_status != null) ...[
              const SizedBox(height: 12),
              Text(_status!),
            ],
          ],
        ),
      ),
    );
  }
}
