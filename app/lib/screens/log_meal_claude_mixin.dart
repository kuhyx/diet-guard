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
  String? _pendingRid;

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
      requestId: newRequestId(),
      slotMinute: targetSlot,
      mode: dueMode ? ClaudeRelayMode.due : ClaudeRelayMode.normal,
      text: claudeDesc.text.trim(),
      photoJpeg: photo,
    );
    unawaited(_relaySub?.cancel());
    _pendingRid = request.requestId;
    setState(() => claudeState = ClaudeButtonState.sending);
    _relaySub = relay.send(request).listen((e) => unawaited(_onEvent(e)));
  }

  Future<void> _onEvent(ClaudeRelayEvent event) async {
    if (!mounted) return;
    switch (event) {
      case ClaudeRelayQueued():
        setState(() => claudeState = ClaudeButtonState.queued);
      case ClaudeRelayLocked():
        _pendingRid = null;
        setState(() => claudeState = ClaudeButtonState.locked);
      case ClaudeRelayFailed():
        _pendingRid = null;
        setState(() => claudeState = ClaudeButtonState.error);
      case ClaudeRelayLogged(:final entry):
        _pendingRid = null;
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

  /// Withdraws a request that is still in flight or queued, because the user
  /// just logged the meal here instead.
  ///
  /// Unclaimed: the node is deleted and the stream dropped. Already claimed
  /// (the PC is mid-estimate): the meal will be logged, so the stream stays
  /// open and its row shows with an undo rather than the entry turning up
  /// unseen after the next sync. That race is accepted, see
  /// `docs/DOCS-claude-relay.md`.
  Future<void> withdrawClaude() async {
    final rid = _pendingRid;
    final waiting =
        claudeState == ClaudeButtonState.sending ||
        claudeState == ClaudeButtonState.queued;
    if (rid == null || !waiting) return;
    if (await relay.cancel(rid)) {
      _pendingRid = null;
      await _relaySub?.cancel();
    }
  }

  /// Cancels the event subscription; call from `dispose`. A request still
  /// queued on the PC reaches this phone through sync instead.
  void disposeClaude() => unawaited(_relaySub?.cancel());
}
