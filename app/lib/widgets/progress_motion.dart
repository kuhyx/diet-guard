/// Motion for the post-log progress card: an entrance and a count-up.
library;

import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// Fades [child] in and slides it up by [AppSpacing.md] when first built.
///
/// Key it per card instance to replay it; under reduced motion the first
/// frame is already the final one.
class ProgressEntrance extends StatelessWidget {
  /// Creates a [ProgressEntrance].
  const ProgressEntrance({required this.child, super.key});

  /// The widget to bring in.
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: 0, end: 1),
    duration: AppDuration.resolve(context, AppDuration.base),
    curve: AppCurve.decelerate,
    child: child,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.translate(
        offset: Offset(0, (1 - t) * AppSpacing.md),
        child: child,
      ),
    ),
  );
}

/// Drives [builder] with a number running from [from] to [to].
///
/// Neutral on purpose: it never knows whether the number is "good", so no
/// value gets a different curve or colour for being under budget. The last
/// frame passes [to] untouched, so callers render exactly the static value.
class CountUp extends StatelessWidget {
  /// Creates a [CountUp].
  const CountUp({
    required this.from,
    required this.to,
    required this.builder,
    super.key,
  });

  /// Starting value.
  final double from;

  /// Final value.
  final double to;

  /// Builds the UI for the current animated value.
  final Widget Function(BuildContext context, double value) builder;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: from, end: to),
    duration: from == to
        ? Duration.zero
        : AppDuration.resolve(context, AppDuration.slow),
    curve: AppCurve.standard,
    builder: (context, value, _) => builder(context, value),
  );
}
