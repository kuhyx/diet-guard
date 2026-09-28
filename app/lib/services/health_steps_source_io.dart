/// Native half of `health_steps_source.dart`: Android Health Connect steps.
///
/// Anything but Android reports unsupported (the Linux `flutter test` VM
/// included), so tests never reach the plugin's platform channel.
library;

import 'dart:io';

import 'package:diet_guard_app/services/health_steps.dart';
import 'package:health/health.dart';

const List<HealthDataType> _types = [HealthDataType.STEPS];
const List<HealthDataAccess> _access = [HealthDataAccess.READ];

/// Health Connect on Android, nothing elsewhere.
StepsSource createStepsSource() => HealthConnectStepsSource();

/// Reads `StepsRecord`s through the `health` plugin.
class HealthConnectStepsSource implements StepsSource {
  Health? _health;

  @override
  bool get supported => Platform.isAndroid;

  // The rest talks to the plugin's platform channel, which `flutter test`
  // has no binding for -- same reason `firebase_backend.dart` is excluded.
  // coverage:ignore-start
  Future<Health> _plugin() async {
    final existing = _health;
    if (existing != null) return existing;
    final health = Health();
    await health.configure();
    return _health = health;
  }

  @override
  Future<bool> hasPermission() async =>
      await (await _plugin()).hasPermissions(_types, permissions: _access) ??
      false;

  @override
  Future<bool> requestPermission() async => await (await _plugin())
      .requestAuthorization(_types, permissions: _access);

  @override
  Future<List<StepInterval>> read(DateTime from, DateTime to) async {
    // Already de-duplicated by the plugin (`removeDuplicates`).
    final points = await (await _plugin()).getHealthDataFromTypes(
      types: _types,
      startTime: from,
      endTime: to,
    );
    return [
      for (final point in points)
        if (point.value case final NumericHealthValue value)
          StepInterval(
            point.dateFrom,
            point.dateTo,
            value.numericValue.toInt(),
          ),
    ];
  }

  // coverage:ignore-end
}
