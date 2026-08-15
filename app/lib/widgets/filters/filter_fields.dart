/// Filter-sheet input widgets shared by the history and food-bank screens.
///
/// Both screens grew the same name-search field, the same slider captions and
/// four copies each of the same min/max macro range block. They live here, in a
/// neutral `widgets/filters/` rather than under either screen, so neither
/// screen owns the other's controls.
library;

import 'package:flutter/material.dart';

/// The free-text "search by name" field in the filter sheet.
///
/// Stateful only to own its [TextEditingController]; the query itself lives in
/// the screen's [HistoryFilter].
class NameSearchField extends StatefulWidget {
  /// Creates a [NameSearchField] seeded with [initialQuery].
  const NameSearchField({
    required this.initialQuery,
    required this.onChanged,
    super.key,
  });

  /// Query text to seed the field with on first build only.
  final String initialQuery;

  /// Called on each edit with the new query.
  final ValueChanged<String> onChanged;

  @override
  State<NameSearchField> createState() => NameSearchFieldState();
}

/// State for [NameSearchField], holding its text controller.
class NameSearchFieldState extends State<NameSearchField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialQuery,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      decoration: const InputDecoration(
        labelText: 'Search by name',
        prefixIcon: Icon(Icons.search),
        isDense: true,
      ),
      onChanged: widget.onChanged,
    );
  }
}

/// The min/max captions printed under a range slider's two ends.
class SliderEndpointLabels extends StatelessWidget {
  /// Creates endpoint labels reading [lo] on the left and [hi] on the right.
  const SliderEndpointLabels({required this.lo, required this.hi, super.key});

  /// Caption for the slider's lower bound.
  final String lo;

  /// Caption for the slider's upper bound.
  final String hi;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Row(
      children: [
        Text(lo, style: style),
        const Spacer(),
        Text(hi, style: style),
      ],
    );
  }
}

/// Centred text showing the currently-selected range value (always visible).
class SliderSelectedLabel extends StatelessWidget {
  /// Creates a centred [label] for the current slider selection.
  const SliderSelectedLabel(this.label, {super.key});

  /// The formatted selection text, e.g. `120 – 640 kcal`.
  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

/// One labelled min/max [RangeSlider] row in the filter sheet.
///
/// The four macro ranges (kcal, protein, carbs, fat) were four near-identical
/// 30-line blocks differing only in label, key, unit suffix and which pair of
/// [HistoryFilter] fields they read and write. Reading and writing go through
/// [min]/[max] and [onChanged] so this widget never needs to know which pair.
class FilterRangeRow extends StatelessWidget {
  /// Creates a range row bounded by [maxValue].
  const FilterRangeRow({
    required this.label,
    required this.sliderKey,
    required this.maxValue,
    required this.min,
    required this.max,
    required this.onChanged,
    this.unit = '',
    this.showEndpointLabels = true,
    super.key,
  });

  /// Section heading, e.g. `Protein range (g)`.
  final String label;

  /// Widget key on the slider itself, so tests can drive one row.
  final Key sliderKey;

  /// Upper bound, derived from the logged data. A value of 0 hides the row.
  final double maxValue;

  /// Current lower bound, or null when unset (meaning 0).
  final double? min;

  /// Current upper bound, or null when unset (meaning [maxValue]).
  final double? max;

  /// Called with the new bounds; null means "no bound", not zero.
  final void Function(double? min, double? max) onChanged;

  /// Suffix appended to the endpoint and selection labels, e.g. `g`.
  final String unit;

  /// Whether to print the endpoint captions and the selected-range readout.
  ///
  /// The history sheet shows both; the food-bank sheet never did, and turning
  /// them on there would be a UI change smuggled in under a refactor.
  final bool showEndpointLabels;

  @override
  Widget build(BuildContext context) {
    if (maxValue <= 0) return const SizedBox.shrink();
    final lo = min ?? 0;
    final hi = max ?? maxValue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        if (showEndpointLabels)
          SliderEndpointLabels(lo: '0', hi: '${maxValue.round()}$unit'),
        RangeSlider(
          key: sliderKey,
          max: maxValue,
          values: RangeValues(lo, hi),
          labels: RangeLabels(lo.toStringAsFixed(0), hi.toStringAsFixed(0)),
          onChanged: (v) => onChanged(
            v.start > 0 ? v.start : null,
            v.end < maxValue ? v.end : null,
          ),
        ),
        if (showEndpointLabels)
          SliderSelectedLabel('${lo.round()} – ${hi.round()}$unit'),
        const SizedBox(height: 8),
      ],
    );
  }
}
