/// Platform entry point for opening the notification backend.
library;

export 'notification_backend_io.dart'
    if (dart.library.js_interop) 'notification_backend_web.dart';
