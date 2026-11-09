/// The pickers behind each tappable mark of the goal row.
///
/// Each returns the edited [Goal], or null when dismissed. Options are icons
/// (plus a number or proper name where one exists); the spoken name of every
/// option is its semantic label.
library;

import 'package:diet_guard_app/services/body_energy.dart';
import 'package:diet_guard_app/ui/cues.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/body/goal_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One choice in a picker sheet.
typedef PickerOption = ({
  String value,
  String spoken,
  IconData icon,
  String? caption,
});

Future<String?> _sheet(
  BuildContext context,
  List<PickerOption> options,
  String selected,
) => showModalBottomSheet<String>(
  context: context,
  builder: (context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: [
          for (final option in options)
            _OptionButton(
              option: option,
              selected: option.value == selected,
              onTap: () => Navigator.of(context).pop(option.value),
            ),
        ],
      ),
    ),
  ),
);

class _OptionButton extends StatelessWidget {
  const _OptionButton({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final PickerOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: option.spoken,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          width: 72,
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outline,
            ),
            color: selected ? scheme.primary.withValues(alpha: 0.16) : null,
          ),
          child: ExcludeSemantics(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(option.icon, color: tint, size: 28),
                if (option.caption != null)
                  Text(
                    option.caption!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: tint),
                  ),
                if (selected)
                  Icon(Icons.check, size: 14, color: scheme.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Lose / maintain / gain.
Future<Goal?> pickDirection(BuildContext context, Goal goal) async {
  final value = await _sheet(context, [
    for (final d in directions)
      (value: d, spoken: d, icon: directionIcon(d), caption: null),
  ], goal.direction);
  return value == null ? null : goal.copyWith(direction: value);
}

/// Kilograms, pounds, grams or stones (the unit symbols are the captions).
Future<Goal?> pickWeightUnit(BuildContext context, Goal goal) async {
  final value = await _sheet(context, [
    for (final u in weightUnits.keys)
      (value: u, spoken: u, icon: Icons.scale, caption: u),
  ], goal.weightUnit);
  return value == null ? null : goal.copyWith(weightUnit: value);
}

/// Per day, week, month or year.
Future<Goal?> pickTimeUnit(BuildContext context, Goal goal) async {
  final value = await _sheet(context, [
    for (final u in timeUnits.keys)
      (value: u, spoken: u, icon: timeUnitIcon(u), caption: null),
  ], goal.timeUnit);
  return value == null ? null : goal.copyWith(timeUnit: value);
}

/// The five levels, then the three measured formulas.
Future<Goal?> pickActivity(BuildContext context, Goal goal) async {
  final value = await _sheet(context, [
    for (final key in activityChoices)
      (
        value: key,
        spoken: activityLabel(key),
        icon: activityIcon(key),
        caption: activityCaption(key),
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
  bool _rejected = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final typed = double.tryParse(_controller.text.replaceAll(',', '.'));
    if (typed != null && typed >= 0) {
      Navigator.of(context).pop(typed);
      return;
    }
    setState(() => _rejected = true);
  }

  @override
  Widget build(BuildContext context) {
    final goal = widget.goal;
    return AlertDialog(
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
          IconField(
            icon: Icons.edit,
            semanticLabel: 'Other amount',
            controller: _controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[0-9.,]')),
            ],
            onSubmitted: (_) => _submit(),
          ),
          if (_rejected)
            const StatusCue(kind: CueKind.error, semanticLabel: 'not a number'),
        ],
      ),
      actions: [
        IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close, semanticLabel: 'Cancel'),
        ),
        IconButton.filled(
          onPressed: _submit,
          icon: const Icon(Icons.check, semanticLabel: 'OK'),
        ),
      ],
    );
  }
}
