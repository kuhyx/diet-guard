/// Picks the [StepsSource] for this platform: Health Connect where
/// `dart:io` exists (Android), nothing on web -- the desktop app is a web
/// build and has no Health Connect.
library;

export 'health_steps_source_io.dart'
    if (dart.library.js_interop) 'health_steps_source_web.dart';
