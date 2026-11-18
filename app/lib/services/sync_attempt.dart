/// Runs one sync and records its outcome for the "not syncing" banner.
///
/// The banner said "Not syncing" on a phone whose sync looked fine, and the
/// release build keeps no log that could say why (see `sync_health.dart`).
/// So a failure here also goes to the board through the app-wide reporter:
/// the next one files its own ticket with the exception that caused it.
/// Inside a WorkManager isolate no reporter is installed, so a background
/// failure is only recorded, not filed.
///
/// Only the sync itself is timed in: screen refreshes after a landed sync
/// run outside, so their errors never mark a working sync as failed.
library;

import 'dart:developer';

import 'package:crdt_sync_flutter/crdt_sync_flutter.dart' show AppErrors;
import 'package:diet_guard_app/services/sync_health.dart';

/// Runs [sync]; records success, or failure plus a `sync.failed` report.
///
/// Returns whether the sync landed. Never throws.
Future<bool> attemptSync(Future<void> Function() sync) async {
  try {
    await sync();
  } on Object catch (error, stackTrace) {
    log(
      'diet_guard sync failed',
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
    AppErrors.instance?.reporter.report(
      'sync.failed',
      error,
      stack: stackTrace,
    );
    await SyncHealth.recordFailure();
    return false;
  }
  await SyncHealth.recordSuccess();
  return true;
}
