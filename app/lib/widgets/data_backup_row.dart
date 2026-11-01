/// Icon-only export and import of every synced document.
library;

import 'dart:async';

import 'package:data_transfer_flutter/data_transfer_flutter.dart';
import 'package:diet_guard_app/services/data_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Suggested file name, identical on every platform.
const exportFileName = 'diet-guard-export.json';

enum _Outcome { idle, ok, failed }

/// Export (Save-as picker / download) and merge-only import buttons.
///
/// Feedback is the button's own icon (check or error) plus haptics.
class DataBackupRow extends StatefulWidget {
  /// Creates a [DataBackupRow]; [onImported] runs after a successful import.
  const DataBackupRow({super.key, this.onImported});

  /// Called after an import merged, so the host can refresh shown values.
  final VoidCallback? onImported;

  @override
  State<DataBackupRow> createState() => _DataBackupRowState();
}

class _DataBackupRowState extends State<DataBackupRow> {
  _Outcome _export = _Outcome.idle;
  _Outcome _import = _Outcome.idle;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<_Outcome> _run(Future<bool> Function() action) async {
    try {
      if (!await action()) return _Outcome.idle;
      unawaited(HapticFeedback.lightImpact());
      return _Outcome.ok;
    } on Object {
      unawaited(HapticFeedback.heavyImpact());
      return _Outcome.failed;
    }
  }

  void _show(void Function() update) {
    if (!mounted) return;
    setState(update);
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _export = _import = _Outcome.idle);
    });
  }

  Future<void> _onExport() async {
    final outcome = await _run(() async {
      final text = await exportAllData();
      return await exportJsonText(fileName: exportFileName, text: text);
    });
    _show(() => _export = outcome);
  }

  Future<void> _onImport() async {
    final outcome = await _run(() async {
      final text = await pickJsonText();
      if (text == null) return false;
      await importAllData(text);
      return true;
    });
    if (outcome == _Outcome.ok) widget.onImported?.call();
    _show(() => _import = outcome);
  }

  Widget _button(
    _Outcome outcome,
    IconData idle,
    String label,
    VoidCallback onPressed,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, semantic) = switch (outcome) {
      _Outcome.idle => (idle, null, label),
      _Outcome.ok => (Icons.check_circle, scheme.primary, '$label: done'),
      _Outcome.failed => (Icons.error, scheme.error, '$label: failed'),
    };
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, color: color, semanticLabel: semantic),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _button(_export, Icons.save_alt, 'Export data', _onExport),
        _button(_import, Icons.file_open, 'Import data', _onImport),
      ],
    );
  }
}
