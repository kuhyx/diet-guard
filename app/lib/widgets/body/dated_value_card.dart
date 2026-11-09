/// Dated-value entry card: save or delete any day, undo a delete, and chart
/// the history. Shared by weight and body fat (see `weight_card.dart`).
library;

import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/ui/cues.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/body/body_section.dart';
import 'package:diet_guard_app/widgets/body/weight_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Enters/deletes a day's value and charts the history.
class DatedValueCard extends StatefulWidget {
  /// Creates the card.
  const DatedValueCard({
    required this.semanticLabel,
    required this.fieldSemanticLabel,
    required this.icon,
    required this.unit,
    required this.min,
    required this.max,
    required this.latest,
    required this.series,
    required this.onSave,
    required this.onDelete,
    required this.onChanged,
    super.key,
  });

  /// Spoken name of the card; never painted.
  final String semanticLabel;

  /// Spoken name of the input; never painted.
  final String fieldSemanticLabel;

  /// Glyph captioning the input.
  final IconData icon;

  /// Unit suffix (`kg`, `%`).
  final String unit;

  /// Smallest accepted value.
  final double min;

  /// Largest accepted value.
  final double max;

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
  Widget? _status;
  (String, double)? _undo;

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
        () => _status = StatusCue(
          key: UniqueKey(),
          kind: CueKind.error,
          icon: widget.icon,
          semanticLabel:
              '${widget.semanticLabel} must be ${whole(widget.min)}-'
              '${whole(widget.max)} ${widget.unit}.',
        ),
      );
      return;
    }
    await widget.onSave(_day, value);
    if (!mounted) return;
    _value.clear();
    setState(() {
      _undo = null;
      _status = StatusCue(
        key: UniqueKey(),
        kind: CueKind.ok,
        semanticLabel: 'Saved ${_fmt(value)} for $_day.',
      );
    });
    widget.onChanged();
  }

  /// Deletes at once; the undo arrow restores the value that was there.
  Future<void> _delete() async {
    final day = _day;
    final removed = [
      for (final point in widget.series)
        if (point.$1 == day) point,
    ];
    await widget.onDelete(day);
    if (!mounted) return;
    setState(() {
      _undo = removed.isEmpty ? null : removed.first;
      _status = StatusCue(
        key: UniqueKey(),
        kind: CueKind.ok,
        icon: Icons.delete_outline,
        semanticLabel: 'Deleted $day.',
      );
    });
    widget.onChanged();
  }

  Future<void> _restore() async {
    final undo = _undo;
    if (undo == null) return;
    await widget.onSave(undo.$1, undo.$2);
    if (!mounted) return;
    setState(() {
      _undo = null;
      _status = null;
    });
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final latest = widget.latest;
    final scheme = Theme.of(context).colorScheme;
    final undo = _undo;
    return BodySection(
      semanticLabel: widget.semanticLabel,
      children: [
        Row(
          children: [
            const Icon(Icons.update, size: 18, semanticLabel: 'Latest'),
            const SizedBox(width: AppSpacing.xs),
            if (latest == null)
              Icon(Icons.block, size: 18, color: scheme.outline)
            else
              // Scales down instead of clipping on a narrow sheet.
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('${_fmt(latest.$2)}  ${latest.$1}', maxLines: 1),
                ),
              ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: IconField(
                icon: widget.icon,
                semanticLabel: widget.fieldSemanticLabel,
                controller: _value,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp('[0-9.,]')),
                ],
              ),
            ),
            TextButton(
              onPressed: _pickDay,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [const Icon(Icons.event, size: 18), Text(' $_day')],
              ),
            ),
          ],
        ),
        Row(
          children: [
            if (_status != null) _status! else const SizedBox.shrink(),
            if (undo != null)
              IconButton(
                onPressed: _restore,
                icon: const Icon(Icons.undo, semanticLabel: 'Undo'),
              ),
            const Spacer(),
            IconButton(
              icon: const Icon(
                Icons.delete_outline,
                semanticLabel: 'Delete this day',
              ),
              onPressed: _delete,
            ),
            IconButton.filled(
              onPressed: _save,
              icon: const Icon(Icons.check, semanticLabel: 'Save'),
            ),
          ],
        ),
        WeightChart(series: widget.series),
      ],
    );
  }
}
