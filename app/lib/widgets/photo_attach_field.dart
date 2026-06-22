/// Shared attach/preview/remove control for a meal entry's optional photo.
library;

import 'dart:io';

import 'package:diet_guard_app/screens/photo_viewer_screen.dart';
import 'package:diet_guard_app/services/photo_attach_service.dart';
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
    super.key,
  });

  /// The currently attached photo's local path, or null if none.
  final String? imagePath;

  /// Called with the new path after a successful pick, or null after the
  /// user removes the current photo.
  final ValueChanged<String?> onChanged;

  Future<void> _attach(BuildContext context) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Take a photo'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from gallery'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(ImageSource.gallery),
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
      return OutlinedButton.icon(
        onPressed: () => _attach(context),
        icon: const Icon(Icons.add_a_photo),
        label: const Text('Attach photo'),
      );
    }
    return Row(
      children: [
        GestureDetector(
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute(builder: (_) => PhotoViewerScreen(path: path)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(path),
              width: 64,
              height: 64,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => const SizedBox(
                width: 64,
                height: 64,
                child: Icon(Icons.broken_image),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: () => onChanged(null),
          child: const Text('Remove photo'),
        ),
      ],
    );
  }
}
