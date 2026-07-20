/// File-backed attached-photo widget (Android).
library;

import 'dart:io';

import 'package:flutter/material.dart';

/// Renders the photo stored under [path], falling back to a broken-image
/// icon when it cannot be read.
class AttachedImage extends StatelessWidget {
  /// Creates an [AttachedImage] for the blob key [path].
  const AttachedImage({
    required this.path,
    this.width,
    this.height,
    this.fit,
    this.errorIconSize,
    this.errorIconColor,
    super.key,
  });

  /// Blob key of the photo -- an absolute file path on this platform.
  final String path;

  /// Optional fixed width; null renders at the image's own size.
  final double? width;

  /// Optional fixed height; null renders at the image's own size.
  final double? height;

  /// How to inscribe the image into its box.
  final BoxFit? fit;

  /// Size of the fallback broken-image icon.
  final double? errorIconSize;

  /// Colour of the fallback broken-image icon.
  final Color? errorIconColor;

  @override
  Widget build(BuildContext context) {
    return Image.file(
      File(path),
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (context, error, stackTrace) => SizedBox(
        width: width,
        height: height,
        child: Icon(
          Icons.broken_image,
          size: errorIconSize,
          color: errorIconColor,
        ),
      ),
    );
  }
}
