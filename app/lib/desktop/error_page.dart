/// A wordless page for an error the window itself loaded: Chrome would
/// otherwise paint its own "This page isn't working" sentences over an
/// empty error body. Only the title carries the app's name (OS-level label).
library;

import 'dart:io';

/// HTML page with only an icon — no words painted by the browser.
const String errorIconPage =
    '<!doctype html><html><head><meta charset="utf-8"> '
    '<title>Diet Guard</title> '
    '<style>html,body{margin:0;height:100%; '
    'background:#211D1B;display:flex;align-items:center; '
    'justify-content:center}</style></head><body> '
    '<svg width="96" height="96" viewBox="0 0 24 24" fill="none" '
    'stroke="#A39892" stroke-width="2" stroke-linecap="round" '
    'aria-hidden="true"><circle cx="12" cy="12" r="9"/> '
    '<line x1="5.6" y1="18.4" x2="18.4" y2="5.6"/></svg></body></html>';

/// Whether [request] is the window loading a page, not the app's fetch().
bool isNavigation(HttpRequest request) =>
    request.headers.value('sec-fetch-mode') == 'navigate';

/// Replaces an error answer to a page load with [errorIconPage]. Does
/// nothing for fetch() calls, successes, or a response already written.
void paintErrorIcon(HttpRequest request) {
  final response = request.response;
  if (!isNavigation(request) || response.statusCode < 400) return;
  try {
    response.headers.contentType = ContentType.html;
    response.write(errorIconPage);
  } on Exception {
    return; // body already sent: leave it alone
  }
}
