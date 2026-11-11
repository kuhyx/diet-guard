/// The endless child delegate of the looping time wheels.
library;

import 'package:flutter/widgets.dart';

/// An endless delegate that passes the absolute index to its builder, so a
/// tapped item knows which of its many copies it is (the framework's
/// looping delegate only hands out the wrapped child).
class LoopWheelDelegate extends ListWheelChildDelegate {
  /// Creates a delegate looping over [count] values.
  LoopWheelDelegate(this.count, this.builder);

  /// Number of distinct values before the wheel wraps.
  final int count;

  /// Builds the item at an absolute (unwrapped) index.
  final Widget Function(int index) builder;

  @override
  Widget? build(BuildContext context, int index) => builder(index);

  @override
  int? get estimatedChildCount => null;

  @override
  int trueIndexOf(int index) => index % count;

  @override
  bool shouldRebuild(covariant ListWheelChildDelegate oldDelegate) => true;
}
