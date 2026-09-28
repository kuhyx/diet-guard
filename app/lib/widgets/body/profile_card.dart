/// Birth date, height and sex -- the synced profile the formulas need.
library;

import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/body/body_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Edits the profile; calls [onSaved] after a successful save.
class ProfileCard extends StatefulWidget {
  /// Creates the card.
  const ProfileCard({required this.onSaved, super.key});

  /// Called once the profile has been written.
  final VoidCallback onSaved;

  @override
  State<ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends State<ProfileCard> {
  final _height = TextEditingController();
  String? _birth;
  String? _sex;
  String? _status;

  @override
  void initState() {
    super.initState();
    final body = BodyService.instance;
    _birth = body.birth;
    _sex = body.sex;
    final height = body.heightCm;
    if (height != null) _height.text = oneDecimal(height);
  }

  @override
  void dispose() {
    _height.dispose();
    super.dispose();
  }

  Future<void> _pickBirth() async {
    final now = DateTime.now();
    final initial = DateTime.tryParse(_birth ?? '') ?? DateTime(now.year - 30);
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(1900),
      lastDate: now,
      initialDate: initial,
      initialDatePickerMode: DatePickerMode.year,
    );
    if (picked == null || !mounted) return;
    setState(() => _birth = localDateKey(picked));
  }

  Future<void> _save() async {
    final height = double.tryParse(_height.text.replaceAll(',', '.'));
    if (height == null || height < 50 || height > 260) {
      setState(() => _status = 'Height must be 50-260 cm.');
      return;
    }
    await BodyService.instance.setProfile(
      birth: _birth,
      heightCm: height,
      sex: _sex,
    );
    if (!mounted) return;
    setState(() => _status = 'Saved.');
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    return BodySection(
      title: 'Profile',
      children: [
        Row(
          children: [
            Expanded(child: Text('Born: ${_birth ?? 'not set'}')),
            TextButton.icon(
              icon: const Icon(Icons.cake),
              label: const Text('Birth date'),
              onPressed: _pickBirth,
            ),
          ],
        ),
        TextField(
          controller: _height,
          decoration: const InputDecoration(labelText: 'Height (cm)'),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp('[0-9.,]')),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'm', label: Text('Male')),
            ButtonSegment(value: 'f', label: Text('Female')),
          ],
          selected: {?_sex},
          emptySelectionAllowed: true,
          onSelectionChanged: (value) =>
              setState(() => _sex = value.isEmpty ? null : value.first),
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(child: BodyNote(_status ?? 'Syncs to the PC.')),
            FilledButton(onPressed: _save, child: const Text('Save profile')),
          ],
        ),
      ],
    );
  }
}
