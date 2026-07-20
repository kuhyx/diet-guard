/// Direct GitHub client, used on Android.
library;

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/services/github_device_auth.dart';
import 'package:diet_guard_app/services/sync_settings.dart';
import 'package:http/http.dart' as http;

/// This device's id in the `diet-guard-sync/devices/<id>/food_log.json`
/// layout.
///
/// The PC's Python side pushes under `pc` (`SYNC_DEVICE_ID` in
/// `diet_guard/_constants.py`) and the desktop web build under `desktop`;
/// every device must have its own, or two of them overwrite each other's
/// pushed log on every tick.
const syncDeviceId = 'phone';

/// Builds a client that talks to `api.github.com` directly with [settings]'
/// token.
GitHubClient createGitHubClient(
  SyncSettings settings, {
  http.Client? httpClient,
}) => GitHubClient(
  owner: settings.owner,
  repo: settings.repo,
  token: settings.token,
  httpClient: httpClient,
);

/// Builds the device-flow client, talking to GitHub directly.
GitHubDeviceAuth createDeviceAuth(
  String clientId, {
  http.Client? httpClient,
}) => GitHubDeviceAuth(clientId: clientId, httpClient: httpClient);
