/// Single-food meal logging screen -- the app's primary, done-criterion
/// screen: "I can open the diet app on my phone and fill meal I ate."
///
/// Two modes. **Due mode** (a slot elapsed with nothing logged) shows only
/// what logging needs: the food field, suggestions, macros and the action row,
/// with the status bar hidden. **Normal mode** adds the app bar, the sync
/// banner and the date row. Either way the action row is photo / Claude /
/// log, and the field never moves between states.
library;

import 'dart:async';

import 'package:diet_guard_app/models/food_suggestion.dart';
import 'package:diet_guard_app/screens/log_meal_actions.dart';
import 'package:diet_guard_app/screens/log_meal_claude_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_due_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_future_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_logged_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_nav_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_progress.dart';
import 'package:diet_guard_app/screens/log_meal_sync_mixin.dart';
import 'package:diet_guard_app/services/claude_relay_client.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_feedback.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_photo_source.dart';
import 'package:diet_guard_app/ui/cues.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/autocomplete_suggestion_list.dart';
import 'package:diet_guard_app/widgets/logged_meal_row.dart';
import 'package:diet_guard_app/widgets/macro_input_row.dart';
import 'package:diet_guard_app/widgets/meal_action_row.dart';
import 'package:diet_guard_app/widgets/sync_health_banner.dart';
import 'package:diet_guard_app/widgets/today_progress_card.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

/// Lets the user log one food item, with food-bank autocomplete.
class LogMealScreen extends StatefulWidget {
  /// Creates a [LogMealScreen].
  const LogMealScreen({super.key, this.httpClient, this.relay, this.photos});

  /// Injectable HTTP client for auto-sync; tests pass a [MockClient].
  final http.Client? httpClient;

  /// Where the sparkle button sends; the app-wide [claudeRelay] when null.
  final ClaudeRelayClient? relay;

  /// Where photos come from; the camera/gallery picker when null.
  final MealPhotoSource? photos;

  @override
  State<LogMealScreen> createState() => _LogMealScreenState();
}

class _LogMealScreenState extends State<LogMealScreen>
    with
        WidgetsBindingObserver,
        LogMealSyncMixin<LogMealScreen>,
        LogMealDueMixin<LogMealScreen>,
        LogMealLoggedMixin<LogMealScreen>,
        LogMealNavMixin<LogMealScreen>,
        LogMealFutureMixin<LogMealScreen>,
        LogMealClaudeMixin<LogMealScreen> {
  @override
  http.Client? get syncHttpClient => widget.httpClient;
  @override
  ClaudeRelayClient get relay => widget.relay ?? claudeRelay;
  @override
  late final MealPhotoSource photoSource =
      widget.photos ?? ImagePickerPhotoSource();

  final TextEditingController _descController = TextEditingController();
  final MacroControllers _macros = MacroControllers();
  @override
  TextEditingController get claudeDesc => _descController;
  @override
  MacroControllers get claudeMacros => _macros;
  List<FoodSuggestion> _suggestions = const [];
  String _source = 'manual';
  CueState? _cue; // painted as a tinted icon, never as text
  TodayProgress? _progress;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _descController.addListener(_onDescChanged);
    _macros.addListenerToAll(_onMacroEdited);
    unawaited(_onDescChanged());
    // Health first, so a device that stalled earlier says so before a tick.
    unawaited(refreshSyncHealth());
    startOpenChain();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    disposeClaude();
    restoreStatusBar();
    _descController.dispose();
    _macros.dispose();
    super.dispose();
  }

  void _onMacroEdited() {
    if (_source == 'food bank') setState(() => _source = 'manual');
  }

  /// Re-runs the food-bank search and dismisses the previous progress card,
  /// only while the field is non-empty: [_onLogMeal]'s own `clear()` fires
  /// this listener too, and would otherwise race it and null the new card.
  Future<void> _onDescChanged() async {
    final matches = await FoodBankService.instance.search(_descController.text);
    if (!mounted) return;
    setState(() {
      _suggestions = matches;
      if (_descController.text.isNotEmpty) _progress = null;
    });
  }

  void _onSuggestionSelected(FoodSuggestion suggestion) {
    fillControllersFromSuggestion(suggestion, _descController, _macros);
    setState(() {
      _source = 'food bank';
      _suggestions = const [];
    });
  }

  Future<void> _onLogMeal() async {
    final desc = _descController.text.trim();
    if (desc.isEmpty) return;
    final target = resolveLogTarget(targetSlot);
    if (target.error != null) {
      setState(() => _cue = CueState.next(_cue, CueKind.error, target.error!));
      return;
    }
    LogFeedback.mealLogged(); // on the tap, before the write
    unawaited(withdrawClaude()); // else Claude would log it a second time
    final entry = await LogStorageService.instance.logMeal(
      desc,
      nutritionFromControllers(_macros, _source),
      slotMinute: target.slot,
      when: target.when,
    );
    resetFutureLog();
    final log = await publishAfterLog();
    if (!mounted) return;
    _descController.clear();
    _macros.clear();
    setState(() {
      _source = 'manual';
      photo = null; // else a stale photo keeps the sparkle lit
      claudeState = ClaudeButtonState.idle;
    });
    await refreshSlots();
    if (!mounted) return;
    showLogged([LoggedMeal(entry, LoggedOrigin.local)]);
    setState(() {
      _cue = null;
      _progress = buildTodayProgress(log, logged: entry);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!slotsLoaded) return const Scaffold();
    final due = dueMode;
    // Dimmed while Claude works, but never moved: nothing is added around it.
    final busy = claudeState == ClaudeButtonState.sending;
    // Hard rule: nothing sits under the keyboard, so the extras collapse.
    final typing = MediaQuery.viewInsetsOf(context).bottom > 0;
    final dim = busy || claudeState == ClaudeButtonState.queued;
    return Scaffold(
      appBar: due
          ? null
          : AppBar(
              actions: logMealAppBarActions(
                onFoodBank: onOpenFoodBank,
                onHistory: onOpenHistory,
                onCalendar: onOpenCalendar,
                onSettings: onOpenSettings,
                onBody: onOpenBody,
                leading: buildDateActions(context),
              ),
            ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!due) SyncHealthBanner(status: syncHealth),
              buildSlotRow(),
              Opacity(
                opacity: dim ? 0.5 : 1,
                child: IgnorePointer(
                  ignoring: busy,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      IconField(
                        controller: _descController,
                        icon: Icons.fastfood,
                        semanticLabel: 'What did you eat?',
                        onChanged: (_) => setState(() {}),
                      ),
                      AutocompleteSuggestionList(
                        suggestions: _suggestions,
                        onSelected: _onSuggestionSelected,
                        compact: true,
                        compactLimit: due ? 2 : 3,
                        reserveHeight: due,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      MacroInputRow(controllers: _macros, compact: true),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              MealActionRow(
                claude: claudeState,
                photoAttached: photo != null,
                canSend: canSend,
                canLog: _descController.text.trim().isNotEmpty,
                onPhoto: () => unawaited(attachPhoto(PhotoOrigin.camera)),
                onGallery: () => unawaited(attachPhoto(PhotoOrigin.gallery)),
                onRemovePhoto: removePhoto,
                onSend: sendToClaude,
                onLog: _onLogMeal,
              ),
              if (!typing)
                for (final meal in loggedRows)
                  LoggedMealRow(meal: meal, onUndo: () => undoLogged(meal)),
              if (_cue != null) ...[
                const SizedBox(height: AppSpacing.sm),
                _cue!.widget,
              ],
              if (_progress != null && !due && !typing) ...[
                const SizedBox(height: AppSpacing.sm),
                TodayProgressCard(progress: _progress!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
