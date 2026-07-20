/// Wrapper-proxied GitHub client, used by the desktop web build.
library;

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/services/desktop_wrapper.dart';
import 'package:diet_guard_app/services/github_device_auth.dart';
import 'package:diet_guard_app/services/sync_settings.dart';
import 'package:http/http.dart' as http;

/// This device's id under `diet-guard-sync/devices/`.
///
/// Distinct from the phone's `phone` and the Python side's `pc`: the desktop
/// app is a third device, and sharing an id would make two devices overwrite
/// each other's pushed log on every tick.
const syncDeviceId = 'desktop';

/// Builds a client whose requests go through the desktop wrapper.
///
/// The token is deliberately empty: the wrapper attaches the real one
/// server-side (see `desktop/github_proxy.dart`), so it never enters the
/// browser. `settings.token` on web is only ever the stand-in constant.
GitHubClient createGitHubClient(
  SyncSettings settings, {
  http.Client? httpClient,
}) => GitHubClient(
  owner: settings.owner,
  repo: settings.repo,
  token: '',
  httpClient: WrapperProxyClient(inner: httpClient),
);

/// Rewrites `https://api.github.com/...` to the wrapper's proxy endpoint.
///
/// A decorator rather than a `baseUrl` option on [GitHubClient] so the shared
/// `crdt_sync` library needs no web-specific knowledge; the rewrite is a
/// property of how this app is hosted, not of the transport.
class WrapperProxyClient extends http.BaseClient {
  /// Creates a client delegating to [inner] after rewriting GitHub URLs.
  WrapperProxyClient({http.Client? inner, this.baseUrl = desktopWrapperOrigin})
    : _inner = inner ?? http.Client();

  final http.Client _inner;

  /// Origin of the desktop wrapper.
  final String baseUrl;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.host != 'api.github.com' || request is! http.Request) {
      return _inner.send(request);
    }
    final rewritten =
        http.Request(
            request.method,
            Uri.parse(
              '$baseUrl${WrapperPaths.github}api'
              '${request.url.path}',
            ).replace(query: request.url.hasQuery ? request.url.query : null),
          )
          ..headers.addAll(request.headers)
          ..bodyBytes = request.bodyBytes
          ..followRedirects = request.followRedirects;
    return _inner.send(rewritten);
  }

  @override
  void close() => _inner.close();
}

/// Builds the device-flow client, routed through the desktop wrapper.
///
/// GitHub's device-flow endpoints send no CORS headers, so the page cannot
/// call them; the wrapper does, and keeps the resulting token.
GitHubDeviceAuth createDeviceAuth(
  String clientId, {
  http.Client? httpClient,
}) => GitHubDeviceAuth(
  clientId: clientId,
  deviceCodeUrl: '$desktopWrapperOrigin${WrapperPaths.github}auth/device/start',
  tokenUrl: '$desktopWrapperOrigin${WrapperPaths.github}auth/device/poll',
  httpClient: httpClient,
);
