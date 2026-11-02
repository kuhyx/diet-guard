import 'dart:async';

import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:flutter/material.dart';

/// Opt-out switch for the log cue, which ships on.
class LogSoundTile extends StatefulWidget {
  /// Creates a [LogSoundTile].
  const LogSoundTile({super.key});

  @override
  State<LogSoundTile> createState() => _LogSoundTileState();
}

class _LogSoundTileState extends State<LogSoundTile> {
  bool _on = AppSettingsService.soundOnLog;

  void _onChanged(bool on) {
    setState(() => _on = on);
    unawaited(AppSettingsService.instance.setSoundOnLog(on: on));
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Align(
      alignment: Alignment.centerLeft,
      child: Icon(
        _on ? Icons.volume_up : Icons.volume_off,
        semanticLabel: 'Sound on log',
      ),
    ),
    value: _on,
    onChanged: _onChanged,
  );
}
