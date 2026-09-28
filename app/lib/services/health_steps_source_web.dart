/// Web half of `health_steps_source.dart`: no Health Connect in a browser.
library;

import 'package:diet_guard_app/services/health_steps.dart';

/// A source that never reads anything.
StepsSource createStepsSource() => const NoStepsSource();

/// Reports "unsupported" and reads nothing.
class NoStepsSource implements StepsSource {
  /// Creates the source.
  const NoStepsSource();

  @override
  bool get supported => false;

  @override
  Future<bool> hasPermission() async => false;

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<List<StepInterval>> read(DateTime from, DateTime to) async => [];
}
