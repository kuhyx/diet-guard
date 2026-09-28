/// Daily steps (from Health Connect, phone-written) as exercise kcal.
///
/// Only steps above [stepBaseline] count: the `BMR x 1.2` sedentary
/// baseline the measured TDEE starts from already assumes a few thousand
/// steps of ordinary movement. The rest are walking at the per-km rate
/// (0.5 kcal per kg per km, net of resting) over a stride estimated from
/// height. Port of `diet_guard/_body_steps.py`.
library;

import 'package:diet_guard_app/services/body_calc.dart';

/// Steps a day the sedentary baseline already covers.
const int stepBaseline = 4000;

// Stride as a fraction of height (the common pedometer estimate).
const double _strideMale = 0.415;
const double _strideFemale = 0.413;
const double _walkKcalPerKgKm = 0.5;
const double _mPerKm = 1000;

/// Estimated walking stride in metres.
double strideM(Biometrics bio) =>
    bio.heightCm / 100.0 * (bio.isMale ? _strideMale : _strideFemale);

/// Net kcal of the steps above the baseline, as walking.
double stepKcal(int steps, Biometrics bio) {
  final extra = steps > stepBaseline ? steps - stepBaseline : 0;
  final km = extra * strideM(bio) / _mPerKm;
  return km * _walkKcalPerKgKm * bio.weightKg;
}
