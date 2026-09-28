/// The pickers behind each tappable word of the goal sentence.
///
/// Each returns the edited [Goal], or null when dismissed.
library;

import 'package:diet_guard_app/services/body_energy.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<String?> _sheet(
  BuildContext context,
  String title,
  List<(String, String, String?)> options,
  String selected,
) => showModalBottomSheet<String>(
  context: context,
  builder: (context) => SafeArea(
    child: ListView(
      shrinkWrap: true,
      children: [
        ListTile(title: Text(title)),
        for (final (value, label, subtitle) in options)
          ListTile(
            title: Text(label),
            subtitle: subtitle == null ? null : Text(subtitle),
            selected: value == selected,
            trailing: value == selected ? const Icon(Icons.check) : null,
            onTap: () => Navigator.of(context).pop(value),
          ),
      ],
    ),
  ),
);

/// Lose / maintain / gain.
Future<Goal?> pickDirection(BuildContext context, Goal goal) async {
  final value = await _sheet(context, 'Direction', [
    for (final d in directions) (d, d, null),
  ], goal.direction);
  return value == null ? null : goal.copyWith(direction: value);
}

/// Kilograms, pounds, grams or stones.
Future<Goal?> pickWeightUnit(BuildContext context, Goal goal) async {
  final value = await _sheet(context, 'Weight unit', [
    for (final u in weightUnits.keys) (u, u, null),
  ], goal.weightUnit);
  return value == null ? null : goal.copyWith(weightUnit: value);
}

/// Per day, week, month or year.
Future<Goal?> pickTimeUnit(BuildContext context, Goal goal) async {
  final value = await _sheet(context, 'Per', [
    for (final u in timeUnits.keys) (u, u, null),
  ], goal.timeUnit);
  return value == null ? null : goal.copyWith(timeUnit: value);
}

/// The five levels, then the three measured formulas.
Future<Goal?> pickActivity(BuildContext context, Goal goal) async {
  final meaning = {for (final l in activityLevels) l.key: l.meaning};
  final value = await _sheet(context, 'Activity', [
    for (final key in activityChoices)
      (
        key,
        activityLabel(key),
        meaning[key] ?? 'BMR x 1.2 + your real workouts and steps',
      ),
  ], goal.activity);
  return value == null ? null : goal.copyWith(activity: value);
}

/// A preset amount, or any typed non-negative number.
Future<Goal?> pickAmount(BuildContext context, Goal goal) async {
  final value = await showDialog<double>(
    context: context,
    builder: (context) => _AmountDialog(goal: goal),
  );
  return value == null ? null : goal.copyWith(amount: value);
}

/// Owns its text controller, so the controller outlives the dialog's exit
/// animation instead of being disposed while the field still paints.
class _AmountDialog extends StatefulWidget {
  const _AmountDialog({required this.goal});

  final Goal goal;

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  late final _controller = TextEditingController(
    text: formatG(widget.goal.amount),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final typed = double.tryParse(_controller.text.replaceAll(',', '.'));
    if (typed != null && typed >= 0) Navigator.of(context).pop(typed);
  }

  @override
  Widget build(BuildContext context) {
    final goal = widget.goal;
    return AlertDialog(
      title: Text('How much (${goal.weightUnit} / ${goal.timeUnit})'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: AppSpacing.xs,
            children: [
              for (final preset in presetAmounts)
                ChoiceChip(
                  label: Text(formatG(preset)),
                  selected: preset == goal.amount,
                  onSelected: (_) => Navigator.of(context).pop(preset),
                ),
            ],
          ),
          TextField(
            controller: _controller,
            decoration: const InputDecoration(labelText: 'Other amount'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[0-9.,]')),
            ],
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('OK')),
      ],
    );
  }
}
