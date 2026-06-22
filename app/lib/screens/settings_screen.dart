/// GitHub sync configuration: paste a PAT, test the connection, and trigger
/// a manual sync. Auto-sync (app launch + lifecycle pause/resume) lives in
/// [LogMealScreen] and is silent on failure -- this screen is where errors
/// get surfaced, via [SnackBar].
library;

import 'dart:async';

import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/github_client.dart';
import 'package:diet_guard_app/services/sync_service.dart';
import 'package:diet_guard_app/services/sync_settings.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Screen for configuring and triggering cross-device sync.
class SettingsScreen extends StatefulWidget {
  /// Creates a [SettingsScreen].
  const SettingsScreen({super.key, this.httpClient});

  /// Injectable HTTP client; tests pass a [MockClient].
  final http.Client? httpClient;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _ownerController = TextEditingController();
  final _repoController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _loading = true;
  bool _busy = false;

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
    _ownerController.text = settings.owner;
    _repoController.text = settings.repo;
    _tokenController.text = settings.token;
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _ownerController.dispose();
    _repoController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  SyncSettings _currentSettings() => SyncSettings(
    owner: _ownerController.text.trim(),
    repo: _repoController.text.trim(),
    token: _tokenController.text.trim(),
  );

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Sync settings')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
              controller: _tokenController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Personal access token',
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
                  child: const Text('Test connection'),
                ),
                ElevatedButton(
                  onPressed: _busy ? null : _syncNow,
                  child: const Text('Sync now'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
