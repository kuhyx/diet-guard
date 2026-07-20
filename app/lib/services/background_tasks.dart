/// Platform entry point for scheduling the app's recurring work.
///
/// Conditional export because `workmanager` has no browser implementation at
/// all -- a closed tab runs nothing. Android schedules real OS-managed
/// background work; the browser-hosted desktop app runs an in-page timer that
/// lives only as long as its window (see `background_tasks_web.dart`).
library;

export 'background_tasks_io.dart'
    if (dart.library.js_interop) 'background_tasks_web.dart';
