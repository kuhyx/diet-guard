/// Platform entry point for building the GitHub sync client.
library;

export 'github_client_factory_io.dart'
    if (dart.library.js_interop) 'github_client_factory_web.dart';
