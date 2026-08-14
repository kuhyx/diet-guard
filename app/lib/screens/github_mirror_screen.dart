/// Sync configuration for the GitHub cutover mirror. Kept app-local rather
/// than folded into the shared `sync_settings_ui` package because connecting
/// here also triggers a real log sync via [_syncAfterConnect] -- unlike the
/// shared package's Firebase section, which only saves settings. See
/// `lib/screens/settings_screen.dart` for the link to this screen and to the
/// shared Sync settings screen.
library;

import 'dart:async';

import 'package:diet_guard_app/services/firebase_backend.dart';
import 'package:diet_guard_app/services/github_client_factory.dart';
import 'package:diet_guard_app/services/github_device_auth.dart';
import 'package:diet_guard_app/services/sync_health.dart';
import 'package:diet_guard_app/services/sync_service.dart';
import 'package:diet_guard_app/services/sync_settings.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// Screen for configuring and triggering the GitHub mirror sync.
class GitHubMirrorScreen extends StatefulWidget {
  /// Creates a [GitHubMirrorScreen].
  const GitHubMirrorScreen({super.key, this.httpClient});

  /// Injectable HTTP client; tests pass a [MockClient].
  final http.Client? httpClient;

  @override
  State<GitHubMirrorScreen> createState() => _GitHubMirrorScreenState();
}

class _GitHubMirrorScreenState extends State<GitHubMirrorScreen> {
  final _ownerController = TextEditingController();
  final _repoController = TextEditingController();
  final _tokenController = TextEditingController();
  final _clientIdController = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  String? _status;

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
  String _storedToken = '';

  SyncSettings _currentSettings() {
    final typed = _tokenController.text.trim();
    return SyncSettings(
      owner: _ownerController.text.trim(),
      repo: _repoController.text.trim(),
      // The `_storedToken` side is web-only (the wrapper holds the real
      // token), so it is unreachable from a VM test.
      token: typed.isEmpty && !SyncSettings.exposesTokenValue
          // coverage:ignore-line
          ? _storedToken
          : typed,
      clientId: _clientIdController.text.trim(),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    setState(() => _status = message);
  }

  /// Runs the OAuth device flow and, on success, fills in the token field.
  Future<void> _connectGitHub() async {
    var clientId = _clientIdController.text.trim();
    if (clientId.isEmpty) {
      final entered = await showDialog<String>(
        context: context,
        builder: (_) => const _ClientIdSetupDialog(),
      );
      if (entered == null || entered.isEmpty) return;
      clientId = entered;
      if (!mounted) return;
      setState(() => _clientIdController.text = clientId);
      await _currentSettings().save();
    }
    final auth = createDeviceAuth(clientId, httpClient: widget.httpClient);
    try {
      final device = await auth.requestDeviceCode();
      if (!mounted) return;
      final token = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _DeviceCodeDialog(device: device, auth: auth),
      );
      if (token != null && token.isNotEmpty) {
        setState(() {
          _storedToken = token;
          if (SyncSettings.exposesTokenValue) _tokenController.text = token;
        });
        _showMessage('Connected — syncing…');
        await _currentSettings().save();
        await _syncAfterConnect();
      }
    } on Exception catch (e) {
      _showMessage('Could not start device flow: $e');
    } finally {
      auth.close();
    }
  }

  /// Runs a sync right after connecting so the device-flow token is proven
  /// to work immediately, with clear confirmation either way.
  Future<void> _syncAfterConnect() async {
    final settings = _currentSettings();
    final client = createGitHubClient(settings, httpClient: widget.httpClient);
    try {
      await runSync(await syncBackend(client));
      await SyncHealth.recordSuccess();
      _showMessage('Connected and synced.');
    } on Exception catch (e) {
      await SyncHealth.recordFailure();
      _showMessage('Connected, but sync failed: $e');
    } finally {
      client.close();
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    await _currentSettings().save();
    if (!mounted) return;
    setState(() => _busy = false);
    _showMessage('Saved.');
  }

  Future<void> _testConnection() async {
    setState(() => _busy = true);
    final settings = _currentSettings();
    final client = createGitHubClient(settings, httpClient: widget.httpClient);
    try {
      final ok = await client.canAccessRepo();
      _showMessage(
        ok ? 'GitHub connection OK.' : 'GitHub connection failed.',
      );
    } on Exception catch (e) {
      _showMessage('GitHub connection failed: $e');
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    final settings = _currentSettings();
    await settings.save();
    final client = createGitHubClient(settings, httpClient: widget.httpClient);
    try {
      await runSync(await syncBackend(client));
      // Clears any stored failure: this is the button a user reaches
      // *because* the banner told them syncing had stopped, so a successful
      // run here must dismiss the warning it caused.
      await SyncHealth.recordSuccess();
      _showMessage('Synced.');
    } on Exception catch (e) {
      await SyncHealth.recordFailure();
      _showMessage('Sync failed: $e');
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

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

/// Dialog shown when "Connect GitHub" is tapped with no OAuth App client id
/// configured yet. Explains what it is, how to get one, and lets the user
/// paste it in directly — rather than leaving them to discover a buried
/// field on their own. Pops the trimmed client id, or null if cancelled.
class _ClientIdSetupDialog extends StatefulWidget {
  const _ClientIdSetupDialog();

  @override
  State<_ClientIdSetupDialog> createState() => _ClientIdSetupDialogState();
}

class _ClientIdSetupDialogState extends State<_ClientIdSetupDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('One-time GitHub setup needed'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Diet Guard signs in via a GitHub OAuth App (no password '
              'typed into this app). You only have to set this up once:',
            ),
            const SizedBox(height: 12),
            const Text(
              '1. On any device, open '
              'github.com/settings/developers → "New OAuth App".\n'
              '2. Name/Homepage/Callback URL can be anything (device flow '
              "doesn't use the callback) — e.g. "
              '"Diet Guard" and your GitHub profile URL.\n'
              '3. Check "Enable Device Flow", then click "Register '
              'application".\n'
              "4. Copy the Client ID shown on the app's page and paste it "
              'below.',
            ),
            const SizedBox(height: 12),
            const Text(
              'When you connect below, log in with the GitHub account that '
              'has write access to kuhyx/syncs.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Client ID'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final id = _controller.text.trim();
            if (id.isNotEmpty) Navigator.of(context).pop(id);
          },
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

/// Dialog shown during the device flow: displays the user code, opens the
/// verification page, and polls until authorized — popping the token (or
/// null if cancelled / failed).
class _DeviceCodeDialog extends StatefulWidget {
  const _DeviceCodeDialog({required this.device, required this.auth});

  final DeviceCodeResponse device;
  final GitHubDeviceAuth auth;

  @override
  State<_DeviceCodeDialog> createState() => _DeviceCodeDialogState();
}

class _DeviceCodeDialogState extends State<_DeviceCodeDialog> {
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_poll());
  }

  Future<void> _poll() async {
    try {
      final token = await widget.auth.pollForToken(widget.device);
      if (mounted) Navigator.of(context).pop(token);
    } on Exception catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _openPage() async {
    await Clipboard.setData(ClipboardData(text: widget.device.userCode));
    await launchUrl(
      Uri.parse(widget.device.verificationUri),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Authorize on GitHub'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Enter this code on GitHub:'),
          const SizedBox(height: 8),
          SelectableText(
            widget.device.userCode,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          if (_error == null)
            const Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Expanded(child: Text('Waiting for authorization…')),
              ],
            )
          else
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _openPage,
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open GitHub & copy code'),
        ),
      ],
    );
  }
}
