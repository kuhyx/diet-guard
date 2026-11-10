/// Returns the activity-type icon for [kind].
library;

import 'package:flutter/material.dart';

/// Activity kind icons used by _SessionTile (in `activity_card.dart`).
IconData kindIcon(String kind) => switch (kind) {
  'run' => Icons.directions_run,
  'walk' => Icons.directions_walk,
  'cycle' => Icons.directions_bike,
  'strength' => Icons.fitness_center,
  _ => Icons.sports,
};
