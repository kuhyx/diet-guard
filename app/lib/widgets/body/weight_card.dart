/// Dated-value entry (any day, save or delete) with its history chart.
///
/// One widget serves both logs -- weight and body fat -- so the two cards
/// cannot drift apart; [WeightCard] and [BodyFatCard] only configure it.
library;

import 'package:diet_guard_app/models/body_document.dart';
import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/widgets/body/body_section.dart';
import 'package:diet_guard_app/widgets/body/weight_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Weight: 20-400 kg; wake-alarm weigh-ins land here too.
class WeightCard extends StatelessWidget {
  /// Creates the card.
  const WeightCard({required this.onChanged, super.key});

  /// Called once a value has been written or deleted.
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final body = BodyService.instance;
    return DatedValueCard(
      title: 'Weight',
      fieldLabel: 'Weight (kg)',
      unit: 'kg',
      min: 20,
      max: 400,
      hint: 'Morning weigh-ins from wake-alarm appear here.',
      latest: body.latestWeight,
      series: body.weightSeries,
      onSave: body.setWeight,
      onDelete: body.deleteWeight,
      onChanged: onChanged,
    );
  }
}

/// Body fat: 3-70 %; the newest reading switches the table to Katch-McArdle.
class BodyFatCard extends StatelessWidget {
  /// Creates the card.
  const BodyFatCard({required this.onChanged, super.key});

  /// Called once a value has been written or deleted.
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final body = BodyService.instance;
    return DatedValueCard(
      title: 'Body fat',
      fieldLabel: 'Body fat (%)',
      unit: '%',
      min: minBodyFat,
      max: maxBodyFat,
      hint: 'With a body fat %, targets use the lean-mass (Katch-McArdle) BMR.',
      latest: body.latestBodyFat,
      series: body.bodyFatSeries,
      onSave: body.setBodyFat,
      onDelete: body.deleteBodyFat,
      onChanged: onChanged,
    );
  }
}

/// Enters/deletes a day's value and charts the history.
class DatedValueCard extends StatefulWidget {
  /// Creates the card.
  const DatedValueCard({
    required this.title,
    required this.fieldLabel,
    required this.unit,
    required this.min,
    required this.max,
    required this.hint,
    required this.latest,
    required this.series,
    required this.onSave,
    required this.onDelete,
    required this.onChanged,
    super.key,
  });

  /// Section heading.
  final String title;

  /// Input label.
  final String fieldLabel;

  /// Unit suffix (`kg`, `%`).
  final String unit;

  /// Smallest accepted value.
  final double min;

  /// Largest accepted value.
  final double max;

  /// Note shown until something is saved.
  final String hint;

  /// Newest `(day, value)`, or null.
  final (String, double)? latest;

  /// Every live `(day, value)`, oldest first.
  final List<(String, double)> series;

  /// Writes a value for a day.
  final Future<void> Function(String day, double value) onSave;

  /// Deletes a day.
  final Future<void> Function(String day) onDelete;

  /// Called once a value has been written or deleted.
  final VoidCallback onChanged;

  @override
  State<DatedValueCard> createState() => _DatedValueCardState();
}

class _DatedValueCardState extends State<DatedValueCard> {
  final _value = TextEditingController();
  String _day = localDateKey(DateTime.now());
  String? _status;

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  String _fmt(double value) => '${oneDecimal(value)} ${widget.unit}';

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
      initialDate: DateTime.parse(_day),
    );
    if (picked == null || !mounted) return;
    setState(() => _day = localDateKey(picked));
  }

  Future<void> _save() async {
    final value = double.tryParse(_value.text.replaceAll(',', '.'));
    if (value == null || value < widget.min || value > widget.max) {
      setState(
        () => _status =
            '${widget.title} must be ${whole(widget.min)}-'
            '${whole(widget.max)} ${widget.unit}.',
      );
      return;
    }
    await widget.onSave(_day, value);
    if (!mounted) return;
    _value.clear();
    setState(() => _status = 'Saved ${_fmt(value)} for $_day.');
    widget.onChanged();
  }

  Future<void> _delete() async {
    await widget.onDelete(_day);
    if (!mounted) return;
    setState(() => _status = 'Deleted $_day.');
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final latest = widget.latest;
    return BodySection(
      title: widget.title,
      children: [
        BodyStatRow(
          'Latest',
          latest == null ? 'none yet' : '${_fmt(latest.$2)} (${latest.$1})',
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _value,
                decoration: InputDecoration(labelText: widget.fieldLabel),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp('[0-9.,]')),
                ],
              ),
            ),
            TextButton(onPressed: _pickDay, child: Text(_day)),
          ],
        ),
        Row(
          children: [
            Expanded(child: BodyNote(_status ?? widget.hint)),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete this day',
              onPressed: _delete,
            ),
            FilledButton(onPressed: _save, child: const Text('Save')),
          ],
        ),
        WeightChart(series: widget.series),
      ],
    );
  }
}
