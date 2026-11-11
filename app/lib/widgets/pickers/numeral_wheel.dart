/// A controlled numeral wheel: the year wheel and both time wheels.
library;

import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/pickers/loop_wheel_delegate.dart';
import 'package:diet_guard_app/widgets/pickers/numeral_cell.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Height of one wheel item.
const double kWheelItemExtent = 40;

/// A wheel of the values `offset .. offset + count - 1`, optionally looping.
///
/// Controlled: [value] is the truth and the wheel animates to it when the
/// parent changes it. Mouse drag scrolls (web excludes the mouse from drag by
/// default), a tap on any item selects it, arrow keys step by one. Values
/// failing [enabled] are dimmed and inert: [onChanged] never reports them and
/// a wheel that settles on one springs back to [value].
class NumeralWheel extends StatefulWidget {
  /// Creates a [NumeralWheel].
  const NumeralWheel({
    required this.count,
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
    this.offset = 0,
    this.loop = false,
    this.digits = 1,
    this.enabled,
    this.autofocus = false,
    super.key,
  });

  /// Number of values.
  final int count;

  /// The value at index 0.
  final int offset;

  /// The current value.
  final int value;

  /// Called with each newly centred allowed value.
  final ValueChanged<int> onChanged;

  /// The spoken name of the wheel ("Year"); never painted.
  final String semanticLabel;

  /// Whether the last value wraps to the first.
  final bool loop;

  /// Zero-padded width of each numeral (2 for `05`).
  final int digits;

  /// Which values may be picked; all when null.
  final bool Function(int value)? enabled;

  /// Whether the wheel takes keyboard focus when it appears.
  final bool autofocus;

  @override
  State<NumeralWheel> createState() => _NumeralWheelState();
}

class _NumeralWheelState extends State<NumeralWheel> {
  late final FixedExtentScrollController _controller =
      FixedExtentScrollController(initialItem: widget.value - widget.offset);
  late int _centred = widget.value - widget.offset;
  bool _focused = false;

  int _valueAt(int index) =>
      widget.offset + (widget.loop ? index % widget.count : index);

  bool _ok(int value) => widget.enabled?.call(value) ?? true;

  /// The index nearest the centre that shows [value] (a loop has many).
  int _indexOf(int value) {
    final target = value - widget.offset;
    if (!widget.loop) return target;
    final n = widget.count;
    final delta = (target - _centred) % n;
    return delta > n ~/ 2 ? _centred + delta - n : _centred + delta;
  }

  void _goTo(int index) => _controller.animateToItem(
    index,
    duration: AppDuration.fast,
    curve: AppCurve.standard,
  );

  bool get _scrolling =>
      _controller.hasClients && _controller.position.isScrollingNotifier.value;

  @override
  void didUpdateWidget(NumeralWheel old) {
    super.didUpdateWidget(old);
    // Not mid-drag: the parent echoing an intermediate value must not yank
    // the wheel out from under the pointer.
    if (widget.value != _valueAt(_centred) && !_scrolling) {
      _afterFrame(() => _goTo(_indexOf(widget.value)));
    }
  }

  void _afterFrame(VoidCallback action) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) action();
      });

  /// The allowed value nearest [value], by value and never across the wrap
  /// (08:00 out of range means 08:15, not 08:59). A fast drag can skip every
  /// allowed value on its way past an end, so the last reported value is no
  /// anchor.
  int _nearestAllowed(int value) {
    final last = widget.offset + widget.count - 1;
    for (var d = 1; d < widget.count; d++) {
      for (final v in [value - d, value + d]) {
        if (v >= widget.offset && v <= last && _ok(v)) return v;
      }
    }
    return widget.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _centre(int index) {
    setState(() => _centred = index);
    final value = _valueAt(index);
    if (_ok(value) && value != widget.value) widget.onChanged(value);
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final step = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => -1,
      LogicalKeyboardKey.arrowDown => 1,
      _ => 0,
    };
    if (step == 0) return KeyEventResult.ignored;
    final next = _centred + step;
    final inList = widget.loop || (next >= 0 && next < widget.count);
    if (inList && _ok(_valueAt(next))) _goTo(next);
    return KeyEventResult.handled;
  }

  Widget _item(BuildContext context, int index) {
    final value = _valueAt(index);
    final ok = _ok(value);
    final scheme = Theme.of(context).colorScheme;
    final centred = index == _centred;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: ok ? () => _goTo(index) : null,
      child: Center(
        child: Text(
          '$value'.padLeft(widget.digits, '0'),
          key: ValueKey('wheel-$value'),
          style: TextStyle(
            fontSize: centred ? AppTextSize.title : AppTextSize.subtitle,
            fontWeight: centred ? FontWeight.bold : null,
            color: scheme.onSurface.withValues(alpha: ok ? 1 : kDisabledAlpha),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final behavior = ScrollConfiguration.of(context).copyWith(
      dragDevices: PointerDeviceKind.values.toSet(),
      scrollbars: false,
    );
    return Semantics(
      label: widget.semanticLabel,
      container: true,
      child: Focus(
        autofocus: widget.autofocus,
        onKeyEvent: _key,
        onFocusChange: (f) => setState(() => _focused = f),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              height: kWheelItemExtent,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                border: _focused
                    ? Border.all(color: scheme.outline, width: 2)
                    : null,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
            ),
            NotificationListener<ScrollEndNotification>(
              onNotification: (_) {
                if (!_ok(_valueAt(_centred))) {
                  _afterFrame(
                    () => _goTo(_indexOf(_nearestAllowed(_valueAt(_centred)))),
                  );
                } else if (_valueAt(_centred) != widget.value) {
                  _afterFrame(() => _goTo(_indexOf(widget.value)));
                }
                return false;
              },
              child: ScrollConfiguration(
                behavior: behavior,
                child: ListWheelScrollView.useDelegate(
                  controller: _controller,
                  itemExtent: kWheelItemExtent,
                  physics: const FixedExtentScrollPhysics(),
                  diameterRatio: 1.6,
                  onSelectedItemChanged: _centre,
                  childDelegate: widget.loop
                      ? LoopWheelDelegate(
                          widget.count,
                          (i) => _item(context, i),
                        )
                      : ListWheelChildBuilderDelegate(
                          childCount: widget.count,
                          builder: _item,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
