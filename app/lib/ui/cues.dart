/// Text-free status cues: tinted icon + shake + haptic instead of sentences.
///
/// Every cue carries its meaning twice (icon shape AND colour) and exposes
/// the old sentence only as a screen-reader label, never as visible text.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

export 'package:diet_guard_app/ui/icon_field.dart';

/// What a [StatusCue] reports.
enum CueKind {
  /// Something worked.
  ok(Icons.check_circle),

  /// Neutral information.
  info(Icons.info),

  /// Caution, e.g. nothing to do or only partly done.
  warn(Icons.warning_amber_rounded),

  /// Something failed or the input was rejected.
  error(Icons.error);

  const CueKind(this.icon);

  /// Default glyph for this kind.
  final IconData icon;

  /// Tint for this kind from the active theme.
  Color tint(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status =
        Theme.of(context).extension<AppStatusColors>() ?? AppStatusColors.dark;
    return switch (this) {
      CueKind.ok => status.success,
      CueKind.info => scheme.onSurfaceVariant,
      CueKind.warn => status.warning,
      CueKind.error => scheme.error,
    };
  }
}

/// A tinted icon chip that replaces a status sentence.
///
/// [CueKind.error] shakes (~3 swings, skipped when the platform asks for
/// reduced motion) and fires a heavy haptic; [CueKind.ok] fires a light one.
/// [semanticLabel] is announced as a live region and is never painted.
class StatusCue extends StatefulWidget {
  /// Creates a cue of [kind]; [icon] overrides the kind's default glyph.
  const StatusCue({
    required this.kind,
    required this.semanticLabel,
    this.icon,
    super.key,
  });

  /// Meaning of the cue.
  final CueKind kind;

  /// Spoken description (screen readers, tests); never painted.
  final String semanticLabel;

  /// Optional glyph replacing [CueKind.icon].
  final IconData? icon;

  @override
  State<StatusCue> createState() => _StatusCueState();
}

class _StatusCueState extends State<StatusCue>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: AppDuration.slow * 2,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_announce());
  }

  Future<void> _announce() async {
    switch (widget.kind) {
      case CueKind.error:
        await HapticFeedback.heavyImpact();
        if (mounted && !MediaQuery.disableAnimationsOf(context)) {
          await _shake.forward();
        }
      case CueKind.ok:
        await HapticFeedback.lightImpact();
      case CueKind.info || CueKind.warn:
        break;
    }
  }

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tint = widget.kind.tint(context);
    return Semantics(
      liveRegion: true,
      label: widget.semanticLabel,
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _shake,
          builder: (context, child) => Transform.translate(
            offset: Offset(math.sin(_shake.value * 6 * math.pi) * 8, 0),
            child: child,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: tint),
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Icon(widget.icon ?? widget.kind.icon, color: tint),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows an icon-only snackbar; [onUndo] adds an undo arrow inside it.
///
/// `SnackBarAction` can only carry text, so the undo is an [IconButton].
void showCueSnack(
  BuildContext context, {
  required CueKind kind,
  required String semanticLabel,
  IconData? icon,
  VoidCallback? onUndo,
}) {
  final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
  final tint = kind.tint(context);
  messenger.showSnackBar(
    SnackBar(
      content: Semantics(
        liveRegion: true,
        label: semanticLabel,
        child: Row(
          children: [
            Icon(icon ?? kind.icon, color: tint),
            const Spacer(),
            if (onUndo != null)
              IconButton(
                icon: const Icon(Icons.undo, semanticLabel: 'Undo'),
                onPressed: () {
                  messenger.hideCurrentSnackBar();
                  onUndo();
                },
              ),
          ],
        ),
      ),
    ),
  );
}

/// One screen's current status cue; [seq] re-keys the widget so an identical
/// consecutive status still shakes/pulses again.
@immutable
class CueState {
  /// Creates the successor of [previous] carrying [kind] and [label].
  CueState.next(CueState? previous, this.kind, this.label)
    : seq = (previous?.seq ?? 0) + 1;

  /// Meaning.
  final CueKind kind;

  /// Spoken description; never painted.
  final String label;

  /// Monotonic counter used as the widget key.
  final int seq;

  /// The left-aligned cue widget for this state.
  Widget get widget => Align(
    alignment: Alignment.centerLeft,
    child: StatusCue(key: ValueKey(seq), kind: kind, semanticLabel: label),
  );
}
