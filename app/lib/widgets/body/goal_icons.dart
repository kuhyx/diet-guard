/// Glyphs for the goal's enumerations (direction, time unit, activity), so
/// the goal reads as a row of icons and numbers instead of a sentence.
library;

import 'package:diet_guard_app/services/body_energy.dart';
import 'package:flutter/material.dart';

/// Lose = down arrow, maintain = level bar, gain = up arrow.
IconData directionIcon(String direction) => switch (direction) {
  'lose' => Icons.south,
  'gain' => Icons.north,
  _ => Icons.drag_handle,
};

/// Day / week / month / year as calendar views of growing span.
IconData timeUnitIcon(String unit) => switch (unit) {
  'day' => Icons.calendar_view_day,
  'week' => Icons.calendar_view_week,
  'month' => Icons.calendar_view_month,
  _ => Icons.event_repeat,
};

/// The five levels ramp from a chair to a barbell; measured is a gauge.
IconData activityIcon(String key) => switch (key) {
  'sedentary' => Icons.chair,
  'light' => Icons.directions_walk,
  'moderate' => Icons.directions_bike,
  'very' => Icons.directions_run,
  'extra' => Icons.fitness_center,
  _ => Icons.speed,
};

/// Short non-word caption under an activity icon: the TDEE multiplier of a
/// level, or the proper name of the measured formula.
String activityCaption(String key) {
  if (key.startsWith(measuredPrefix)) {
    return key.substring(measuredPrefix.length);
  }
  for (final level in activityLevels) {
    if (level.key == key) return formatG(level.factor);
  }
  return key;
}
