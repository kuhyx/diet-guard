/// Full-screen, pinch-to-zoom view of a locally attached meal photo.
library;

import 'dart:io';

import 'package:flutter/material.dart';

/// Shows the image at [path] full-screen, with pinch-to-zoom and a back
/// button to dismiss.
class PhotoViewerScreen extends StatelessWidget {
  /// Creates a [PhotoViewerScreen] for the photo at [path].
  const PhotoViewerScreen({required this.path, super.key});

  /// Local filesystem path to the image to display.
  final String path;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: InteractiveViewer(
          child: Image.file(
            File(path),
            errorBuilder: (context, error, stackTrace) => const Icon(
              Icons.broken_image,
              color: Colors.white,
              size: 64,
            ),
          ),
        ),
      ),
    );
  }
}
