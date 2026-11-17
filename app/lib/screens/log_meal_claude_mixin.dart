/// The sparkle button: send the typed text and/or photo to Claude.
///
/// Its own file because `log_meal_screen.dart` is at the repo's 250-line
/// ceiling. The transport is behind [ClaudeRelayClient]; this only drives the
/// button's states and shows the meal Claude logged.
///
/// The photo lives in [photo] for one send and nowhere else.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:diet_guard_app/screens/log_meal_due_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_future_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_logged_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_sync_mixin.dart';
import 'package:diet_guard_app/services/claude_relay_client.dart';
import 'package:diet_guard_app/services/log_entry_lookup.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_photo_source.dart';
import 'package:diet_guard_app/widgets/logged_meal_row.dart';
import 'package:diet_guard_app/widgets/macro_input_row.dart';
import 'package:diet_guard_app/widgets/meal_action_row.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

/// Photo attach and the Claude send, for the log screen's state.
mixin LogMealClaudeMixin<T extends StatefulWidget>
    on
        LogMealSyncMixin<T>,
        LogMealDueMixin<T>,
        LogMealLoggedMixin<T>,
        LogMealFutureMixin<T> {
  /// The relay this screen sends through. Supplied by the screen.
  ClaudeRelayClient get relay;

  /// Where photos come from. Supplied by the screen.
  MealPhotoSource get photoSource;

  /// The food field. Supplied by the screen.
  TextEditingController get claudeDesc;

  /// The macro fields. Supplied by the screen.
  MacroControllers get claudeMacros;

  /// The sparkle button's state.
  ClaudeButtonState claudeState = ClaudeButtonState.idle;

  /// The attached photo's JPEG bytes, or null. Never stored or synced.
  Uint8List? photo;

  StreamSubscription<ClaudeRelayEvent>? _relaySub;

  /// Whether there is something to send (a description or a photo).
  bool get canSend =>
      futureDate == null &&
      (claudeDesc.text.trim().isNotEmpty || photo != null);

  /// Attaches a photo from [origin]; backing out keeps the current one.
  Future<void> attachPhoto(PhotoOrigin origin) async {
    final bytes = await photoSource.pick(origin);
    if (!mounted || bytes == null) return;
    setState(() => photo = bytes);
  }

  /// Drops the attached photo.
  void removePhoto() => setState(() => photo = null);

  /// Sends the form to Claude and follows the request's events.
  void sendToClaude() {
    if (!canSend) return;
    final request = ClaudeRelayRequest(
      requestId: const Uuid().v4(),
      slotMinute: targetSlot,
      text: claudeDesc.text.trim(),
      photoJpeg: photo,
    );
    unawaited(_relaySub?.cancel());
    setState(() => claudeState = ClaudeButtonState.sending);
    _relaySub = relay.send(request).listen((e) => unawaited(_onEvent(e)));
  }

  Future<void> _onEvent(ClaudeRelayEvent event) async {
    if (!mounted) return;
    switch (event) {
      case ClaudeRelayQueued():
        setState(() => claudeState = ClaudeButtonState.queued);
      case ClaudeRelayLocked():
        setState(() => claudeState = ClaudeButtonState.locked);
      case ClaudeRelayFailed():
        setState(() => claudeState = ClaudeButtonState.error);
      case ClaudeRelayLogged(:final entry):
        // The worker logged it under the request id; the sync would deliver
        // the same record, so this only shows it now and never doubles it.
        final stored = await LogStorageService.instance.addIfAbsent(entry);
        if (!mounted) return;
        claudeDesc.clear();
        claudeMacros.clear();
        setState(() {
          claudeState = ClaudeButtonState.idle;
          photo = null;
        });
        showLogged([LoggedMeal(stored, LoggedOrigin.claude)]);
        await publishAfterLog();
        await refreshSlots();
    }
  }

  /// Cancels the event subscription; call from `dispose`. A request still
  /// queued on the PC reaches this phone through sync instead.
  void disposeClaude() => unawaited(_relaySub?.cancel());
}
