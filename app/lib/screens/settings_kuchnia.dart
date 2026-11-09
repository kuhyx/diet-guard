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
import 'package:diet_guard_app/ui/cues.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// What a delivery fetch reports: a cue [kind], a spoken [label] (never
/// painted) and, when dishes were banked, their [count] (painted as a number).
class FetchOutcome {
  /// Creates an outcome.
  const FetchOutcome(this.kind, this.label, {this.count});

  /// Icon/colour of the cue.
  final CueKind kind;

  /// Spoken description; never painted.
  final String label;

  /// Dishes banked, shown as a bare number next to the cue.
  final int? count;
}

/// Fetches today's delivery and reports what was banked.
///
/// Deliberately "banked", not "logged": a delivered meal is not an eaten
/// meal, so the dishes land in the food bank and the user still taps to log
/// each one. Top-level so the settings screen can pass it without growing.
Future<FetchOutcome> fetchTodaysDelivery() async {
  final result = await refreshDelivery(DateTime.now());
  if (!result.ok) return FetchOutcome(CueKind.error, result.reason!);
  if (result.dishes.isEmpty) {
    return const FetchOutcome(CueKind.warn, 'No delivery found for today.');
  }
  final count = result.dishes.length;
  return FetchOutcome(CueKind.ok, '$count dishes added', count: count);
}

/// Credential fields plus, on Android, a "fetch today's delivery" action.
class KuchniaSettingsSection extends StatefulWidget {
  /// Creates the section.
  ///
  /// [canFetch] defaults to [kuchniaFetchSupported] -- false on web, where the
  /// button is replaced by a one-line explanation rather than silently
  /// vanishing. [onFetch] defaults to the real fetch. Both are injectable so a
  /// widget test can drive the section without a network or a platform check.
  const KuchniaSettingsSection({this.canFetch, this.onFetch, super.key});

  /// Whether this platform can reach the catering panel; null means ask.
  final bool? canFetch;

  /// Fetches today's delivery and returns a status line; null means the real
  /// one.
  final Future<FetchOutcome> Function()? onFetch;

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
  Widget? _status;

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
    setState(
      () => _status = StatusCue(
        key: UniqueKey(),
        kind: CueKind.ok,
        semanticLabel: 'Saved. It will sync to your other devices.',
      ),
    );
  }

  Future<void> _fetch() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    final outcome = await (widget.onFetch ?? fetchTodaysDelivery)();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AppSpacing.sm,
        children: [
          StatusCue(
            key: UniqueKey(),
            kind: outcome.kind,
            semanticLabel: outcome.label,
          ),
          if (outcome.count != null) Text('${outcome.count}'),
        ],
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final canFetch = widget.canFetch ?? kuchniaFetchSupported;
    // The section owns its own leading divider so the settings screen needs a
    // single line for it -- that file sits on the repo's 250-line ceiling.
    // No heading or blurb: the delivery truck on the fetch button names it.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppWidth.field),
          child: IconField(
            icon: Icons.alternate_email,
            semanticLabel: 'Panel e-mail',
            controller: _username,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            onSubmitted: (_) => _save(),
          ),
        ),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppWidth.field),
          child: IconField(
            icon: Icons.key,
            semanticLabel: 'Panel password',
            controller: _password,
            obscure: _obscured,
            autocorrect: false,
            onSubmitted: (_) => _save(),
            suffix: IconButton(
              icon: Icon(
                _obscured ? Icons.visibility : Icons.visibility_off,
                semanticLabel: _obscured ? 'Show password' : 'Hide password',
              ),
              onPressed: () => setState(() => _obscured = !_obscured),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            IconButton.filled(
              onPressed: _save,
              icon: const Icon(Icons.check, semanticLabel: 'Save login'),
            ),
            // Browser builds show the button greyed out: the panel blocks
            // browser requests, and the disabled state is the cue.
            IconButton.outlined(
              onPressed: canFetch && !_busy ? _fetch : null,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(
                      Icons.local_shipping_outlined,
                      semanticLabel: "Fetch today's delivery",
                    ),
            ),
          ],
        ),
        if (_status != null) ...[const SizedBox(height: 8), _status!],
      ],
    );
  }
}
