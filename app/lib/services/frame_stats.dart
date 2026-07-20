/// Optional frame-cadence instrument, armed with
/// `--dart-define=DIET_GUARD_FRAME_STATS=1`.
///
/// Reports **frame-to-frame cadence**, not build/raster durations: work that
/// fits the budget says nothing about the frame rate actually achieved, which
/// is the number the desktop migration exists to move.
///
/// Read with `String.fromEnvironment`, never `bool.fromEnvironment` -- the
/// latter only accepts the literal `true`, so `=1` would silently evaluate to
/// false and a whole measurement run would produce no data while looking like
/// a broken callback.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show FramePhase;

import 'package:diet_guard_app/services/desktop_wrapper.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;

/// Whether the instrument is armed for this build.
const frameStatsEnabled =
    String.fromEnvironment('DIET_GUARD_FRAME_STATS') == '1';

/// Starts collecting frame-to-frame intervals and periodically posts a
/// summary to the desktop wrapper, which writes it to disk.
///
/// The wrapper is used as the sink because a browser cannot write a file and
/// reading its console from outside needs a debugger attached; a POST lands
/// somewhere a measurement run can simply read.
// coverage:ignore-start
void startFrameStats({Duration reportEvery = const Duration(seconds: 2)}) {
  final intervalsMs = <double>[];
  int? previousMicros;

  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final timing in timings) {
      final micros = timing.timestampInMicroseconds(FramePhase.rasterFinish);
      if (previousMicros != null) {
        intervalsMs.add((micros - previousMicros!) / 1000);
      }
      previousMicros = micros;
    }
  });

  Timer.periodic(reportEvery, (_) {
    if (intervalsMs.isEmpty) return;
    final sample = [...intervalsMs]..sort();
    intervalsMs.clear();
    double percentile(double fraction) =>
        sample[(sample.length * fraction).floor().clamp(
          0,
          sample.length - 1,
        )];
    unawaited(
      http.post(
        Uri.parse(
          '$desktopWrapperOrigin${WrapperPaths.documents}'
          'frame_stats.json',
        ),
        body: jsonEncode({
          'frames': sample.length,
          'p50_ms': percentile(0.50),
          'p95_ms': percentile(0.95),
          'max_ms': sample.last,
          'fps_at_p50': 1000 / percentile(0.50),
          'fps_at_p95': 1000 / percentile(0.95),
        }),
      ),
    );
  });
}

// coverage:ignore-end
