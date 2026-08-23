/// App settings: kcal goal, notifications, and links to the two sync
/// surfaces.
///
/// "Sync settings" is the shared `sync_settings_ui` package (Firebase
/// only -- diet_guard has no local backup format, so `BackupSlot` is null).
/// "Advanced sync (GitHub)" stays app-local ([GitHubMirrorScreen]) because
/// connecting it also triggers a real log sync via `runSync`, which the
/// shared package's Firebase section does not do -- it only saves settings.
library;

import 'dart:async';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/screens/github_mirror_screen.dart';
import 'package:diet_guard_app/screens/settings_kuchnia.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/due_slot_check.dart';
import 'package:diet_guard_app/services/firebase_backend.dart';
import 'package:diet_guard_app/services/firebase_client.dart';
import 'package:diet_guard_app/services/google_sign_in_backend.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:sync_settings_ui/sync_settings_ui.dart';

part 'settings_kcal_goal.dart';
part 'settings_meal_schedule.dart';

/// Screen for app-specific settings and links to sync configuration.
class SettingsScreen extends StatefulWidget {
  /// Creates a [SettingsScreen].
  const SettingsScreen({
    super.key,
    this.httpClient,
    this.requestBatteryExemption,
    this.googleFirebaseFactory,
    this.googleAvailable,
    this.accountLoader,
    this.accountSaver,
    this.accountClearer,
    this.sessionProbe,
    this.firebaseFactory,
  });

  /// Injectable HTTP client for the linked [GitHubMirrorScreen]; tests pass
  /// a [MockClient].
  final http.Client? httpClient;

  /// Injectable battery-optimization-exemption request; tests pass a fake.
  /// Production defaults to
  /// `Permission.ignoreBatteryOptimizations.request()`.
  final Future<PermissionStatus> Function()? requestBatteryExemption;

  /// Builds the Firebase backend via Google sign-in, for the shared Sync
  /// settings screen. Injected so tests need no platform channel -- the
  /// plugin reaches the OS account picker.
  final Future<FirebaseRestClient?> Function()? googleFirebaseFactory;

  /// Whether to offer the Google button. Defaults to what the platform
  /// supports; injected by tests, whose host reports unsupported.
  final bool? googleAvailable;

  /// Reads the stored Firebase account. Injected for the same reason as
  /// [googleFirebaseFactory]: the keystore is a platform channel.
  ///
  /// Deliberately backed by [storedAccount], not [loadAccount]: the shared
  /// `SyncSettingsScreen` uses this single closure both to display the
  /// status and to read back the account right after a Google sign-in.
  /// [loadAccount]'s desktop-wrapper fallback resolves to `file:///` on
  /// Android and throws -- verified on the phone, where it turned a
  /// successful sign-in into "Google sign-in failed". `storedAccount` is the
  /// keystore-only read [firebase_backend.dart] documents for exactly this
  /// read-back case.
  final Future<FirebaseAccount?> Function()? accountLoader;

  /// Persists the account. See [accountLoader].
  final Future<void> Function(FirebaseAccount)? accountSaver;

  /// Forgets the account and any cached session. See [accountLoader].
  final Future<void> Function()? accountClearer;

  /// Whether a Firebase session is stored. See [accountLoader].
  final Future<bool> Function()? sessionProbe;

  /// Builds the Firebase backend from the stored account. Injected so tests
  /// can supply a fake.
  final Future<FirebaseRestClient?> Function()? firebaseFactory;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with _SettingsKcalGoal, _SettingsMealSchedule {
  final _kcalGoalController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _kcalGoalController.text = AppSettingsService.dailyKcalGoal.toString();
    _loadSchedule();
  }

  @override
  void dispose() {
    _kcalGoalDebounce?.cancel();
    // Leaving the screen inside the debounce window must not silently drop
    // the edit the user just typed.
    _flushKcalGoal();
    _kcalGoalController.dispose();
    super.dispose();
  }

  /// True on the one platform with OEM battery optimization to exempt from.
  ///
  /// Uses [defaultTargetPlatform] rather than `Platform.isAndroid` because
  /// `dart:io` is a throwing stub in the desktop web build.
  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _openSyncSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SyncSettingsScreen(
          accountLoader: widget.accountLoader ?? storedAccount,
          accountSaver: widget.accountSaver ?? saveAccount,
          accountClearer: widget.accountClearer ?? clearAccount,
          sessionProbe: widget.sessionProbe ?? isFirebaseConfigured,
          firebaseFactory: widget.firebaseFactory ?? openFirebase,
          googleFirebaseFactory:
              widget.googleFirebaseFactory ?? openFirebaseWithGoogle,
          googleAvailable: widget.googleAvailable ?? googleSignInSupported,
        ),
      ),
    );
  }

  Future<void> _openGitHubMirror() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => GitHubMirrorScreen(httpClient: widget.httpClient),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      // Centred and capped at the prose width. On the desktop surface this
      // ListView spanned the full ~1366px window, so the explanatory
      // paragraphs below ran ~180 characters per line -- roughly twice the
      // readable limit (tokens.md rule 21) -- and every field stretched with
      // them. Invisible on the phone, where the window is already narrow.
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppWidth.prose),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('Nutrition', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              // A four-digit number: capped so the field does not read as a
              // layout error by spanning the whole column.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: AppWidth.field),
                child: TextField(
                  controller: _kcalGoalController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Daily kcal goal',
                    helperText: 'Shown in the history day summary',
                    suffixText: 'kcal',
                  ),
                  onChanged: _onKcalGoalChanged,
                ),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),
              ..._mealScheduleSection(context),
              const KuchniaSettingsSection(),
              const SizedBox(height: 24),
              const Divider(),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Sync settings'),
                subtitle: const Text('Firebase sync'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => unawaited(_openSyncSettings()),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Advanced sync (GitHub)'),
                subtitle: const Text('Cutover mirror — not recommended'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => unawaited(_openGitHubMirror()),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),
              Text(
                'Notifications',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                _isAndroid
                    ? 'A background check nags you every ~15 min if a '
                          'meal slot is overdue. Aggressive OEM battery '
                          'optimization (MIUI, some Samsung configs) can '
                          'delay this well past 15 min -- request an '
                          'exemption for reliable nagging.'
                    : 'A check runs every 5 min while this window is open and '
                          'notifies you about an overdue meal slot. A browser '
                          'cannot run anything once the window is closed -- on '
                          'the PC the real backstop is the diet_guard gate, '
                          'which locks the screen instead.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              // Battery-optimization exemption is Android-only, and
              // `permission_handler` has no web implementation at all;
              // the row would throw rather than degrade in the browser.
              if (_isAndroid) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _requestBatteryExemption,
                  icon: const Icon(Icons.battery_alert),
                  label: const Text('Disable battery optimization'),
                ),
              ],
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
