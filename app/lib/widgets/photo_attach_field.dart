/// Shared attach/preview/remove control for a meal entry's optional photo.
library;

import 'package:diet_guard_app/screens/photo_viewer_screen.dart';
import 'package:diet_guard_app/services/photo_attach_service.dart';
import 'package:diet_guard_app/widgets/attached_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Shows an "Attach photo" button when [imagePath] is null, or a tappable
/// thumbnail (opens [PhotoViewerScreen] full-screen) plus a "Remove photo"
/// action once one is set.
///
/// Used identically by the single-item and composite-meal logging screens,
/// so the attach/preview/remove behavior only needs to be implemented once.
class PhotoAttachField extends StatelessWidget {
  /// Creates a [PhotoAttachField].
  const PhotoAttachField({
    required this.imagePath,
    required this.onChanged,
    this.compact = false,
    super.key,
  });

  /// The currently attached photo's local path, or null if none.
  final String? imagePath;

  /// Called with the new path after a successful pick, or null after the
  /// user removes the current photo.
  final ValueChanged<String?> onChanged;

  /// Whether to render an icon-only button and a small thumbnail badge
  /// instead of the default text button and 64x64 preview.
  final bool compact;

  Future<void> _attach(BuildContext context) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // No camera row on web: the browser's picker is a file input,
            // and `ImageSource.camera` silently falls back to the same file
            // dialog -- an option that lies about what it does is worse than
            // no option.
            if (!kIsWeb)
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: const Text('Take a photo'),
                onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
              ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text(
                kIsWeb ? 'Choose a file' : 'Choose from gallery',
              ),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final path = await PhotoAttachService.instance.pickAndStore(source);
    if (path != null) onChanged(path);
  }

  @override
  Widget build(BuildContext context) {
    final path = imagePath;
    if (path == null) {
      if (compact) {
        return Tooltip(
          message: 'Attach photo',
          child: IconButton(
            onPressed: () => _attach(context),
            icon: const Icon(Icons.add_a_photo),
          ),
        );
      }
      return OutlinedButton.icon(
        onPressed: () => _attach(context),
        icon: const Icon(Icons.add_a_photo),
        label: const Text('Attach photo'),
      );
    }
    final thumbnailSize = compact ? 32.0 : 64.0;
    final thumbnail = GestureDetector(
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => PhotoViewerScreen(path: path)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: AttachedImage(
          path: path,
          width: thumbnailSize,
          height: thumbnailSize,
          fit: BoxFit.cover,
        ),
      ),
    );
    if (compact) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          thumbnail,
          Positioned(
            top: -6,
            right: -6,
            child: Tooltip(
              message: 'Remove photo',
              child: InkWell(
                onTap: () => onChanged(null),
                customBorder: const CircleBorder(),
                child: const CircleAvatar(
                  radius: 9,
                  child: Icon(Icons.close, size: 12),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        thumbnail,
        const SizedBox(width: 8),
        TextButton(
          onPressed: () => onChanged(null),
          child: const Text('Remove photo'),
        ),
      ],
    );
  }
}
