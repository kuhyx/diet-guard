/// The log form's action row (variant 1A): photo, send to Claude, log here.
///
/// Three solid icon buttons and no words. The photo button is blue (tap =
/// camera, long press = gallery); an attached photo turns it into a tinted
/// button with a check badge and a small remove badge, and never shows the
/// picture. The gold sparkle sends the text and/or photo to Claude; the green
/// check logs what is typed. Both are greyed until there is something to
/// send or log.
library;

import 'package:diet_guard_app/ui/theme.dart';
import 'package:material_ui/material_ui.dart';

/// What the sparkle button shows.
enum ClaudeButtonState {
  /// Ready (sparkle), or greyed when [MealActionRow.canSend] is false.
  idle,

  /// A request is in flight (spinner).
  sending,

  /// The PC is offline; the request waits (hourglass).
  queued,

  /// Sync is locked, nothing can be sent (lock).
  locked,

  /// The last send failed (error glyph); a tap retries.
  error,
}

/// The photo button's blue, the same hue as the fat figure.
const photoButtonColor = Color(0xFF6C9BD1);

/// Photo, Claude and log buttons side by side.
class MealActionRow extends StatelessWidget {
  /// Creates the row.
  const MealActionRow({
    required this.claude,
    required this.photoAttached,
    required this.canSend,
    required this.canLog,
    required this.onPhoto,
    required this.onGallery,
    required this.onRemovePhoto,
    required this.onSend,
    required this.onLog,
    super.key,
  });

  /// State of the sparkle button.
  final ClaudeButtonState claude;

  /// Whether a photo is attached.
  final bool photoAttached;

  /// Whether there is text or a photo to send.
  final bool canSend;

  /// Whether there is a description to log.
  final bool canLog;

  /// Tap on the photo button: the camera.
  final VoidCallback onPhoto;

  /// Long press on the photo button: the gallery.
  final VoidCallback onGallery;

  /// The remove badge.
  final VoidCallback onRemovePhoto;

  /// The sparkle button.
  final VoidCallback onSend;

  /// The check button.
  final VoidCallback onLog;

  static const double _height = 56;

  @override
  Widget build(BuildContext context) {
    final status =
        Theme.of(context).extension<AppStatusColors>() ?? AppStatusColors.dark;
    final gold = Theme.of(context).colorScheme.primary;
    final sendable =
        canSend &&
        claude != ClaudeButtonState.sending &&
        claude != ClaudeButtonState.queued;
    return Row(
      children: [
        Expanded(child: _photo(status.success)),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: _solid(
            color: gold,
            onPressed: sendable ? onSend : null,
            child: _claudeFace(),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: _solid(
            color: status.success,
            onPressed: canLog ? onLog : null,
            child: const Icon(Icons.check_circle, semanticLabel: 'Log meal'),
          ),
        ),
      ],
    );
  }

  Widget _solid({
    required Color color,
    required VoidCallback? onPressed,
    required Widget child,
    VoidCallback? onLongPress,
    Color? foreground,
  }) => FilledButton(
    onPressed: onPressed,
    onLongPress: onLongPress,
    style: FilledButton.styleFrom(
      backgroundColor: color,
      foregroundColor: foreground ?? const Color(0xFF211D1B),
      minimumSize: const Size.fromHeight(_height),
    ),
    child: child,
  );

  Widget _claudeFace() => switch (claude) {
    ClaudeButtonState.sending => const SizedBox(
      width: 24,
      height: 24,
      child: CircularProgressIndicator(strokeWidth: 3),
    ),
    ClaudeButtonState.queued => const Icon(
      Icons.hourglass_top,
      semanticLabel: 'Waiting for the PC',
    ),
    ClaudeButtonState.locked => const Icon(
      Icons.lock,
      semanticLabel: 'Sync is locked',
    ),
    ClaudeButtonState.error => const Icon(
      Icons.error_outline,
      semanticLabel: 'Claude failed',
    ),
    ClaudeButtonState.idle => const Icon(
      Icons.auto_awesome,
      semanticLabel: 'Ask Claude',
    ),
  };

  Widget _photo(Color success) {
    final button = _solid(
      color: photoAttached
          ? photoButtonColor.withValues(alpha: 0.25)
          : photoButtonColor,
      foreground: photoAttached ? photoButtonColor : null,
      onPressed: onPhoto,
      onLongPress: onGallery,
      child: const Icon(Icons.add_a_photo, semanticLabel: 'Photo'),
    );
    if (!photoAttached) return button;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        button,
        Positioned(
          top: -6,
          left: -6,
          child: _badge(Icons.check, success, null, 'Photo attached'),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: _badge(
            Icons.close,
            photoButtonColor,
            onRemovePhoto,
            'Remove photo',
          ),
        ),
      ],
    );
  }

  /// A 24 dp badge inside a 32 dp hit area, so the remove target is usable.
  Widget _badge(
    IconData icon,
    Color color,
    VoidCallback? onTap,
    String label,
  ) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: SizedBox(
      width: 32,
      height: 32,
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: SizedBox(
            width: 22,
            height: 22,
            child: Icon(
              icon,
              size: 16,
              color: const Color(0xFF211D1B),
              semanticLabel: label,
            ),
          ),
        ),
      ),
    ),
  );
}
