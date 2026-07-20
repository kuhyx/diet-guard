/// IndexedDB-backed attached-photo widget (desktop web build).
library;

import 'dart:typed_data';

import 'package:diet_guard_app/services/photo_attach_service.dart';
import 'package:flutter/material.dart';

/// Renders the photo stored under [path], falling back to a broken-image
/// icon when it cannot be read.
///
/// Unlike the Android build this is inherently asynchronous: the bytes come
/// from IndexedDB (or, for a cleared profile, the desktop wrapper's disk
/// mirror), not from a path the rasteriser can open itself.
class AttachedImage extends StatefulWidget {
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

  /// Blob key of the photo -- an IndexedDB key on this platform.
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
  State<AttachedImage> createState() => _AttachedImageState();
}

class _AttachedImageState extends State<AttachedImage> {
  late Future<Uint8List?> _bytes = _load();

  Future<Uint8List?> _load() => PhotoAttachService.instance.readBytes(
    widget.path,
  );

  @override
  void didUpdateWidget(AttachedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _bytes = _load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) {
          // Covers both "still loading" and "gone": a spinner that flashes
          // for one frame per thumbnail would be worse than an empty box.
          return SizedBox(
            width: widget.width,
            height: widget.height,
            child: snapshot.connectionState == ConnectionState.done
                ? Icon(
                    Icons.broken_image,
                    size: widget.errorIconSize,
                    color: widget.errorIconColor,
                  )
                : null,
          );
        }
        return Image.memory(
          bytes,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
        );
      },
    );
  }
}
