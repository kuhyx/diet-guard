/// The catering-panel credential section of the settings screen.
///
/// Its own file because `settings_screen.dart` sits at the repo's 250-line
/// ceiling.
///
/// Two things about this section are deliberate:
///
/// * **The fields show on every platform, the fetch button only on Android.**
///   The panel sends no CORS headers, so a browser cannot call it -- but the
///   desktop app is where the user is most likely to be typing a password, and
///   the credential syncs, so hiding the fields there would mean the phone
///   could only ever be set up by typing on the phone.
/// * **The password is stored and synced in plaintext**, and the section says
///   so rather than implying otherwise. The rest of the synced state is not
///   encrypted either.
library;

import 'package:diet_guard_app/services/kuchnia_client.dart';
import 'package:diet_guard_app/services/kuchnia_credential_service.dart';
import 'package:diet_guard_app/services/kuchnia_import.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// Fetches today's delivery and reports what was banked.
///
/// Deliberately says "banked", not "logged": a delivered meal is not an eaten
/// meal, so the dishes land in the food bank and the user still taps to log
/// each one. Top-level so the settings screen can pass it without growing.
Future<String> fetchTodaysDelivery() async {
  final result = await refreshDelivery(DateTime.now());
  if (!result.ok) return result.reason!;
  if (result.dishes.isEmpty) return 'No delivery found for today.';
  final count = result.dishes.length;
  return '$count ${count == 1 ? 'dish' : 'dishes'} added to your food bank. '
      'Log them from the meal screen when you eat them.';
}

/// Credential fields plus, on Android, a "fetch today's delivery" action.
class KuchniaSettingsSection extends StatefulWidget {
  /// Creates the section.
  ///
  /// [canFetch] defaults to [kuchniaFetchSupported] -- false on web, where the
  /// button is replaced by a one-line explanation rather than silently
  /// vanishing. [onFetch] defaults to the real fetch. Both are injectable so a
  /// widget test can drive the section without a network or a platform check.
  const KuchniaSettingsSection({
    this.canFetch,
    this.onFetch,
    super.key,
  });

  /// Whether this platform can reach the catering panel; null means ask.
  final bool? canFetch;

  /// Fetches today's delivery and returns a status line; null means the real
  /// one.
  final Future<String> Function()? onFetch;

  @override
  State<KuchniaSettingsSection> createState() => _KuchniaSettingsSectionState();
}

class _KuchniaSettingsSectionState extends State<KuchniaSettingsSection> {
  late final TextEditingController _username = TextEditingController(
    text: KuchniaCredentialService.username,
  );
  late final TextEditingController _password = TextEditingController(
    text: KuchniaCredentialService.password,
  );
  bool _obscured = true;
  bool _busy = false;
  String? _status;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!KuchniaCredentialService.isInitialized) return;
    await KuchniaCredentialService.instance.save(
      _username.text,
      _password.text,
    );
    if (!mounted) return;
    setState(() => _status = 'Saved. It will sync to your other devices.');
  }

  Future<void> _fetch() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    final message = await (widget.onFetch ?? fetchTodaysDelivery)();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canFetch = widget.canFetch ?? kuchniaFetchSupported;
    // The section owns its own leading divider so the settings screen needs a
    // single line for it -- that file sits on the repo's 250-line ceiling.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 8),
        Text('Kuchnia Wikinga', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          "Your catering panel login, so this device can look up the day's "
          'delivered dishes and their macros. Stored and synced in plain '
          'text, like the rest of your synced data.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppWidth.field),
          child: TextField(
            controller: _username,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Panel e-mail'),
            onSubmitted: (_) => _save(),
          ),
        ),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppWidth.field),
          child: TextField(
            controller: _password,
            obscureText: _obscured,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Panel password',
              suffixIcon: IconButton(
                icon: Icon(_obscured ? Icons.visibility : Icons.visibility_off),
                tooltip: _obscured ? 'Show password' : 'Hide password',
                onPressed: () => setState(() => _obscured = !_obscured),
              ),
            ),
            onSubmitted: (_) => _save(),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(onPressed: _save, child: const Text('Save login')),
            if (canFetch)
              OutlinedButton.icon(
                onPressed: _busy ? null : _fetch,
                icon: const Icon(Icons.restaurant),
                label: Text(
                  _busy ? 'Fetching…' : "Fetch today's delivery",
                ),
              ),
          ],
        ),
        if (!canFetch) ...[
          const SizedBox(height: 8),
          Text(
            'Android only — the catering panel blocks browser requests. Your '
            'login still syncs to your phone from here.',
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (_status != null) ...[
          const SizedBox(height: 8),
          Text(_status!, style: theme.textTheme.bodyMedium),
        ],
      ],
    );
  }
}
