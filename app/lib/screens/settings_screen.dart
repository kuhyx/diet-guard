/// GitHub sync configuration. Primary path: "Connect GitHub" runs the OAuth
/// **device flow** (authorize in a browser, no token pasting). A manually
/// pasted PAT remains as a fallback under "Advanced". Auto-sync (app launch
/// + lifecycle pause/resume) lives in [LogMealScreen] and is silent on
/// failure -- this screen is where errors get surfaced, as inline status
/// text.
library;

import 'dart:async';

import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/github_client.dart';
import 'package:diet_guard_app/services/github_device_auth.dart';
import 'package:diet_guard_app/services/sync_service.dart';
import 'package:diet_guard_app/services/sync_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

/// Screen for configuring and triggering cross-device sync.
class SettingsScreen extends StatefulWidget {
  /// Creates a [SettingsScreen].
  const SettingsScreen({
    super.key,
    this.httpClient,
    this.requestBatteryExemption,
  });

  /// Injectable HTTP client; tests pass a [MockClient].
  final http.Client? httpClient;

  /// Injectable battery-optimization-exemption request; tests pass a fake.
  /// Production defaults to
  /// `Permission.ignoreBatteryOptimizations.request()`.
  final Future<PermissionStatus> Function()? requestBatteryExemption;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _kcalGoalController = TextEditingController();
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
    } on Exception {
      settings = const SyncSettings(owner: '', repo: '', token: '');
    }
    if (!mounted) return;
    _kcalGoalController.text = AppSettingsService.dailyKcalGoal.toString();
    _ownerController.text = settings.owner;
    _repoController.text = settings.repo;
    _tokenController.text = settings.token;
    _clientIdController.text = settings.clientId;
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _kcalGoalController.dispose();
    _ownerController.dispose();
    _repoController.dispose();
    _tokenController.dispose();
    _clientIdController.dispose();
    super.dispose();
  }

  SyncSettings _currentSettings() => SyncSettings(
    owner: _ownerController.text.trim(),
    repo: _repoController.text.trim(),
    token: _tokenController.text.trim(),
    clientId: _clientIdController.text.trim(),
  );

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
    final auth = GitHubDeviceAuth(
      clientId: clientId,
      httpClient: widget.httpClient,
    );
    try {
      final device = await auth.requestDeviceCode();
      if (!mounted) return;
      final token = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _DeviceCodeDialog(device: device, auth: auth),
      );
      if (token != null && token.isNotEmpty) {
        setState(() => _tokenController.text = token);
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
    final client = GitHubClient(
      owner: settings.owner,
      repo: settings.repo,
      token: settings.token,
      httpClient: widget.httpClient,
    );
    try {
      await runSync(client);
      _showMessage('Connected and synced.');
    } on Exception catch (e) {
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
    final client = GitHubClient(
      owner: settings.owner,
      repo: settings.repo,
      token: settings.token,
      httpClient: widget.httpClient,
    );
    try {
      final ok = await client.canAccessRepo();
      _showMessage(ok ? 'Connection OK.' : 'Connection failed.');
    } on Exception catch (e) {
      _showMessage('Connection failed: $e');
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    final settings = _currentSettings();
    await settings.save();
    final client = GitHubClient(
      owner: settings.owner,
      repo: settings.repo,
      token: settings.token,
      httpClient: widget.httpClient,
    );
    try {
      await runSync(client);
      _showMessage('Synced.');
    } on Exception catch (e) {
      _showMessage('Sync failed: $e');
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Requests exemption from OEM battery optimization (MIUI, some Samsung
  /// configs), which can otherwise degrade the 15-minute background-check
  /// reliability well past its accepted ±15 min target.
  Future<void> _requestBatteryExemption() async {
    final request =
        widget.requestBatteryExemption ??
        () => Permission.ignoreBatteryOptimizations.request();
    try {
      final status = await request();
      _showMessage(
        status.isGranted
            ? 'Battery optimization exemption granted.'
            : 'Exemption not granted -- notifications may be delayed.',
      );
    } on Exception catch (e) {
      _showMessage('Could not request exemption: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Nutrition', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _kcalGoalController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Daily kcal goal',
              helperText: 'Shown in the history day summary',
              suffixText: 'kcal',
            ),
            onChanged: (v) {
              final n = int.tryParse(v);
              if (n != null && n > 0) {
                unawaited(AppSettingsService.instance.saveDailyKcalGoal(n));
              }
            },
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          Text(
            'Authorize in your browser — no token to paste. Syncs to '
            'kuhyx/syncs by default.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _connectGitHub,
            icon: const Icon(Icons.login),
            label: const Text('Connect GitHub'),
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
          ExpansionTile(
            title: const Text('Advanced'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            children: [
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
                decoration: const InputDecoration(
                  labelText: 'Personal access token (fallback)',
                ),
              ),
            ],
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
                child: const Text('Test connection'),
              ),
              ElevatedButton(
                onPressed: _busy ? null : _syncNow,
                child: const Text('Sync now'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          Text('Notifications', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'A background check nags you every ~15 min if a meal slot is '
            'overdue. Aggressive OEM battery optimization (MIUI, some '
            'Samsung configs) can delay this well past 15 min -- request an '
            'exemption for reliable nagging.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _requestBatteryExemption,
            icon: const Icon(Icons.battery_alert),
            label: const Text('Disable battery optimization'),
          ),
          if (_status != null) ...[
            const SizedBox(height: 16),
            Text(_status!, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}

/// Dialog shown when "Connect GitHub" is tapped with no OAuth App client id
/// configured yet. Explains what it is, how to get one, and lets the user
/// paste it in directly — rather than leaving them to discover a buried
/// "Advanced" field on their own. Pops the trimmed client id, or null if
/// cancelled.
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
            Text(_error!, style: const TextStyle(color: Colors.red)),
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
