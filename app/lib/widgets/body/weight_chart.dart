/// The weight-history line chart with 30d / 90d / 1y / all range chips.
///
/// X is days since the first plotted point, so gaps between weigh-ins are
/// drawn to scale rather than evenly spaced.
library;

import 'package:diet_guard_app/ui/theme.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// Selectable chart ranges, `(label, days)`; null days = everything.
const List<(String, int?)> weightChartRanges = [
  ('30d', 30),
  ('90d', 90),
  ('1y', 365),
  ('All', null),
];

/// Filters [series] (oldest first) to the last [days] before [today].
List<(String, double)> seriesInRange(
  List<(String, double)> series,
  int? days,
  DateTime today,
) {
  if (days == null) return series;
  final cutoff = DateTime(today.year, today.month, today.day - days);
  return [
    for (final point in series)
      if (!DateTime.parse(point.$1).isBefore(cutoff)) point,
  ];
}

/// A line chart of weights with its range selector.
class WeightChart extends StatefulWidget {
  /// Creates the chart for [series] (`(YYYY-MM-DD, kg)`, oldest first).
  const WeightChart({required this.series, this.today, super.key});

  /// Weights to plot.
  final List<(String, double)> series;

  /// Overrides "today" for tests.
  final DateTime? today;

  @override
  State<WeightChart> createState() => _WeightChartState();
}

class _WeightChartState extends State<WeightChart> {
  int? _days = 90;

  @override
  Widget build(BuildContext context) {
    final points = seriesInRange(
      widget.series,
      _days,
      widget.today ?? DateTime.now(),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          children: [
            for (final (label, days) in weightChartRanges)
              ChoiceChip(
                label: Text(label),
                selected: _days == days,
                onSelected: (_) => setState(() => _days = days),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: 200,
          child: points.length < 2
              ? const Center(child: Text('Need two readings for a graph.'))
              : _chart(context, points),
        ),
      ],
    );
  }

  Widget _chart(BuildContext context, List<(String, double)> points) {
    final scheme = Theme.of(context).colorScheme;
    final origin = DateTime.parse(points.first.$1);
    double x(String day) =>
        DateTime.parse(day).difference(origin).inHours / 24.0;
    final spots = [for (final (day, kg) in points) FlSpot(x(day), kg)];
    final kgs = [for (final (_, kg) in points) kg];
    final low = kgs.reduce((a, b) => a < b ? a : b);
    final high = kgs.reduce((a, b) => a > b ? a : b);
    final span = x(points.last.$1).clamp(1, double.infinity).toDouble();
    return LineChart(
      LineChartData(
        minY: (low - 1).floorToDouble(),
        maxY: (high + 1).ceilToDouble(),
        gridData: const FlGridData(drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: true, reservedSize: 40),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: span / 3,
              getTitlesWidget: (value, meta) => SideTitleWidget(
                meta: meta,
                child: Text(
                  _dayLabel(origin, value),
                  style: const TextStyle(fontSize: AppTextSize.caption),
                ),
              ),
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            color: scheme.primary,
            barWidth: 3,
            dotData: FlDotData(show: spots.length <= 60),
          ),
        ],
      ),
    );
  }
}

String _dayLabel(DateTime origin, double offset) {
  final day = DateTime(origin.year, origin.month, origin.day + offset.round());
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(day.day)}.${two(day.month)}';
}
