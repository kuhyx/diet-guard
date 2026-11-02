import 'dart:async';

import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/confirm_cue_player.dart';
import 'package:flutter/services.dart';

/// `lightImpact` + `confirm` on a recorded meal, whatever its kcal.
abstract final class LogFeedback {
  /// Swapped out by test/flutter_test_config.dart.
  static Future<void> Function() playConfirmCue = playConfirmCueAsset;

  /// Fires both without awaiting, so the write is not delayed.
  static void mealLogged() {
    unawaited(HapticFeedback.lightImpact());
    if (AppSettingsService.soundOnLog) {
      unawaited(playConfirmCue());
    }
  }
}
