/// Full-screen, pinch-to-zoom view of a locally attached meal photo.
library;

import 'package:diet_guard_app/widgets/attached_image.dart';
import 'package:flutter/material.dart';

/// Shows the image at [path] full-screen, with pinch-to-zoom and a back
/// button to dismiss.
class PhotoViewerScreen extends StatelessWidget {
  /// Creates a [PhotoViewerScreen] for the photo at [path].
  const PhotoViewerScreen({required this.path, super.key});

  /// Blob key of the image to display (a file path on Android, an IndexedDB
  /// key in the desktop web build).
  final String path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
      ),
      body: Center(
        child: InteractiveViewer(
          child: AttachedImage(
            path: path,
            errorIconSize: 64,
            errorIconColor: scheme.onSurface,
          ),
        ),
      ),
    );
  }
}
