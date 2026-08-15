// Connect / save / test / sync actions for the GitHub mirror screen.
//
// Split out of `github_mirror_screen.dart` for the repo's 250-line cap. A
// `part` rather than a separate library: every one of these methods drives
// the screen's private state (`_busy`, `_status`, `_storedToken`, the four
// controllers) and calls its private helpers, none of which are reachable
// across a library boundary in Dart.
//
// A mixin rather than an extension, because these call `setState`, which is
// `@protected` -- an extension is not a subclass of `State`, so the analyzer
// (correctly) rejects it there.

part of 'github_mirror_screen.dart';

mixin _GitHubMirrorActions on State<GitHubMirrorScreen> {
  // The four text controllers stay declared on the State, which creates and
  // disposes them; the mixin only reads and writes their text.
  TextEditingController get _ownerController;
  TextEditingController get _repoController;
  TextEditingController get _tokenController;
  TextEditingController get _clientIdController;

  bool _busy = false;
  String? _status;
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
        builder: (_) => DeviceCodeDialog(device: device, auth: auth),
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
}
