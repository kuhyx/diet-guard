/// Sync configuration for the GitHub cutover mirror. Kept app-local rather
/// than folded into the shared `sync_settings_ui` package because connecting
/// here also triggers a real log sync via [_syncAfterConnect] -- unlike the
/// shared package's Firebase section, which only saves settings. See
/// `lib/screens/settings_screen.dart` for the link to this screen and to the
/// shared Sync settings screen.
library;

import 'dart:async';

import 'package:diet_guard_app/services/firebase_client.dart';
import 'package:diet_guard_app/services/github_client_factory.dart';
import 'package:diet_guard_app/services/sync_health.dart';
import 'package:diet_guard_app/services/sync_service.dart';
import 'package:diet_guard_app/services/sync_settings.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:github_device_auth/github_device_auth.dart';
import 'package:http/http.dart' as http;

part 'github_client_id_dialog.dart';
part 'github_mirror_actions.dart';

/// Screen for configuring and triggering the GitHub mirror sync.
class GitHubMirrorScreen extends StatefulWidget {
  /// Creates a [GitHubMirrorScreen].
  const GitHubMirrorScreen({super.key, this.httpClient});

  /// Injectable HTTP client; tests pass a [MockClient].
  final http.Client? httpClient;

  @override
  State<GitHubMirrorScreen> createState() => _GitHubMirrorScreenState();
}

class _GitHubMirrorScreenState extends State<GitHubMirrorScreen>
    with _GitHubMirrorActions {
  @override
  final _ownerController = TextEditingController();
  @override
  final _repoController = TextEditingController();
  @override
  final _tokenController = TextEditingController();
  @override
  final _clientIdController = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Loads saved settings, defaulting to blank fields if loading itself
  /// fails (e.g. no secret service available yet) -- the screen must still
  /// render, not spin forever, so the user can fill them in from scratch.
  Future<void> _load() async {
    SyncSettings settings;
    try {
      settings = await SyncSettings.load();
      // SyncSettings.load()'s only awaited calls are SharedPreferences
      // (always mocked successfully under flutter test) and the token
      // vault, whose own read() already swallows its errors internally --
      // so this catch has no reachable path from a VM test, the same reason
      // _currentSettings()'s web-only branch below is marked unreachable.
      // coverage:ignore-start
    } on Exception {
      settings = const SyncSettings(owner: '', repo: '', token: '');
      // coverage:ignore-end
    }
    if (!mounted) return;
    _ownerController.text = settings.owner;
    _repoController.text = settings.repo;
    // On web the stored "token" is only a stand-in for one the desktop
    // wrapper holds (see TokenVault); showing it would invite the user to
    // edit a literal. [_storedToken] keeps it for round-tripping.
    _storedToken = settings.token;
    _tokenController.text = SyncSettings.exposesTokenValue
        ? settings.token
        : '';
    _clientIdController.text = settings.clientId;
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _ownerController.dispose();
    _repoController.dispose();
    _tokenController.dispose();
    _clientIdController.dispose();
    super.dispose();
  }

  /// The token as loaded, so a platform that cannot display it (web) still
  /// round-trips it instead of blanking it on the next save.





  /// Runs the OAuth device flow and, on success, fills in the token field.


  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Advanced sync (GitHub)')),
      // Centred and capped at the prose width -- see settings_screen.dart's
      // note on why: on the desktop surface an uncapped ListView spanned the
      // full window, so explanatory paragraphs ran far past the readable
      // line-length limit.
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppWidth.prose),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Syncs still mirror to GitHub until every device has moved '
                'to Firebase. Authorize in your browser — no token to '
                'paste.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: _connectGitHub,
                  icon: const Icon(Icons.login),
                  label: const Text('Connect GitHub'),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _ownerController,
                decoration: const InputDecoration(labelText: 'GitHub owner'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _repoController,
                decoration: const InputDecoration(labelText: 'Repo'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _clientIdController,
                decoration: const InputDecoration(
                  labelText: 'OAuth App client id',
                  helperText: 'Needed for the Connect GitHub button',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _tokenController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Personal access token (fallback)',
                  // Both wrapper hints are web-only; a VM test always takes
                  // the null branch.
                  // coverage:ignore-start
                  helperText: SyncSettings.exposesTokenValue
                      ? null
                      : _storedToken.isEmpty
                      ? 'Stored by the desktop wrapper, never by the browser'
                      : 'A token is stored by the desktop wrapper; type '
                            'here only to replace it',
                  // coverage:ignore-end
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                children: [
                  ElevatedButton(
                    onPressed: _busy ? null : _save,
                    child: const Text('Save'),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : _testConnection,
                    // Named for what it actually does: _testConnection builds
                    // a GitHub client and calls canAccessRepo(). It says
                    // nothing about Firebase, and the bare label implied
                    // otherwise.
                    child: const Text('Test GitHub connection'),
                  ),
                  ElevatedButton(
                    onPressed: _busy ? null : _syncNow,
                    child: const Text('Sync now'),
                  ),
                ],
              ),
              if (_status != null) ...[
                const SizedBox(height: 16),
                Text(_status!, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
