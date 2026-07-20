/// Local HTTP server backing the desktop app.
///
/// The desktop app is a Flutter **web** build (Flutter's Linux embedder
/// manages only ~20fps at 4K, where the same Dart code in Chrome sustains
/// ~144fps -- see `~/todo/docs/desktop-performance-findings.md`), so it runs
/// in a browser and cannot touch the filesystem. This process is the other
/// half of the desktop app:
///
/// * it serves the built web assets;
/// * it owns an on-disk copy of every document and photo the app stores, so a
///   wiped Chrome profile is not a total-loss event (photos in particular
///   never sync, so nothing else could restore them);
/// * it fronts GitHub, holding the sync token and running the CORS-less
///   device flow the page cannot (see `github_proxy.dart`).
///
/// Binds to loopback only. The endpoints overwrite files in the user's home
/// directory with no authentication, so exposing them on a routable address
/// would let anything on the network rewrite the food log.
library;

import 'dart:async';
import 'dart:io';

import 'package:diet_guard_app/desktop/github_proxy.dart';
import 'package:diet_guard_app/services/desktop_wrapper.dart';
import 'package:path/path.dart' as p;

/// Serves the desktop app's web build plus its disk-backed endpoints.
class WrapperServer {
  /// Creates a server serving [webRoot], mirroring the app's storage under
  /// [dataDir], and proxying GitHub through [gitHubProxy].
  WrapperServer({
    required this.webRoot,
    required this.dataDir,
    required this.gitHubProxy,
  });

  /// Directory holding the built Flutter web assets.
  final String webRoot;

  /// Directory holding the on-disk copies of documents and photo blobs.
  final String dataDir;

  /// GitHub half of the wrapper.
  final GitHubProxy gitHubProxy;

  HttpServer? _server;

  /// Port the server is listening on, once [start] has completed.
  int get port => _server!.port;

  /// Binds to loopback on [requestedPort] and begins serving.
  ///
  /// Pass 0 to let the OS choose a port (tests do this); the desktop launcher
  /// passes [desktopWrapperPort], because the browser keys IndexedDB by
  /// origin -- a changing port would look like an app with no history.
  Future<void> start(int requestedPort) async {
    _server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      requestedPort,
    );
    unawaited(_serve(_server!));
  }

  /// Stops serving and releases the port.
  Future<void> stop() async {
    await _server?.close(force: true);
    gitHubProxy.close();
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      try {
        await _handle(request);
      } on Exception {
        request.response.statusCode = HttpStatus.internalServerError;
      }
      await request.response.close();
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (path.startsWith(WrapperPaths.github)) {
      final rest = path.substring(WrapperPaths.github.length);
      if (await gitHubProxy.handle(request, rest)) return;
      request.response.statusCode = HttpStatus.notFound;
      return;
    }
    if (path.startsWith(WrapperPaths.documents)) {
      return _storedFile(
        request,
        'documents',
        path.substring(WrapperPaths.documents.length),
      );
    }
    if (path.startsWith(WrapperPaths.blobs)) {
      return _storedFile(
        request,
        'blobs',
        path.substring(WrapperPaths.blobs.length),
      );
    }
    return _static(request, path);
  }

  /// GET returns the stored bytes (404 when absent); POST overwrites them.
  ///
  /// [name] is rejected unless it is a plain filename: these handlers write
  /// into the user's home directory, so a `..` segment would turn a mirror
  /// write into an arbitrary-file overwrite.
  Future<void> _storedFile(
    HttpRequest request,
    String subdirectory,
    String name,
  ) async {
    if (name.isEmpty || name.contains('/') || name.contains('..')) {
      request.response.statusCode = HttpStatus.badRequest;
      return;
    }
    final file = File(p.join(dataDir, subdirectory, name));
    if (request.method == 'POST') {
      await file.parent.create(recursive: true);
      final bytes = [for (final chunk in await request.toList()) ...chunk];
      await file.writeAsBytes(bytes);
      request.response.statusCode = HttpStatus.noContent;
      return;
    }
    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      return;
    }
    if (!file.existsSync()) {
      request.response.statusCode = HttpStatus.notFound;
      return;
    }
    request.response.headers.contentType = subdirectory == 'documents'
        ? ContentType.json
        : ContentType.binary;
    await request.response.addStream(file.openRead());
  }

  Future<void> _static(HttpRequest request, String path) async {
    final relative = path == '/' ? 'index.html' : path.substring(1);
    // Reject traversal before touching the filesystem: the served root sits
    // next to the user's files, so `../` must not escape it.
    final resolved = p.normalize(p.join(webRoot, relative));
    // coverage:ignore-start
    // Defence in depth, and currently unreachable: Dart's HttpServer decodes
    // and normalises the path before a handler runs, so even `%2e%2e` arrives
    // already collapsed. Kept so the guarantee does not depend on that
    // implementation detail holding.
    if (!p.isWithin(webRoot, resolved) && resolved != p.normalize(webRoot)) {
      request.response.statusCode = HttpStatus.forbidden;
      return;
    }
    // coverage:ignore-end
    final file = File(resolved);
    if (!file.existsSync()) {
      request.response.statusCode = HttpStatus.notFound;
      return;
    }
    request.response.headers.contentType = contentTypeFor(resolved);
    await request.response.addStream(file.openRead());
  }

  /// Content type for [filePath].
  ///
  /// Flutter web is strict here: CanvasKit refuses to instantiate a `.wasm`
  /// served as anything but `application/wasm`, and the app then renders
  /// nothing at all.
  static ContentType contentTypeFor(String filePath) {
    switch (p.extension(filePath).toLowerCase()) {
      case '.html':
        return ContentType.html;
      case '.js' || '.mjs':
        return ContentType('text', 'javascript', charset: 'utf-8');
      case '.json':
        return ContentType.json;
      case '.wasm':
        return ContentType('application', 'wasm');
      case '.css':
        return ContentType('text', 'css', charset: 'utf-8');
      case '.png':
        return ContentType('image', 'png');
      case '.jpg' || '.jpeg':
        return ContentType('image', 'jpeg');
      case '.svg':
        return ContentType('image', 'svg+xml');
      case '.ttf':
        return ContentType('font', 'ttf');
      case '.otf':
        return ContentType('font', 'otf');
      case '.woff2':
        return ContentType('font', 'woff2');
      default:
        return ContentType.binary;
    }
  }
}
