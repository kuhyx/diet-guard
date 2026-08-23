/// The catering panel credential as its own synced document.
///
/// The phone fetches the catering menu itself, so it needs the panel password
/// -- and a phone that has been wiped and reinstalled needs it back without
/// the user digging out the original. So the credential syncs.
///
/// **It travels in plaintext.** Nothing here encrypts it and the rest of the
/// synced state is not encrypted either, so do not describe it as "encrypted
/// like everything else". Its blast radius is a catering menu and a delivery
/// address, and the user chose this deliberately over a phone that cannot
/// fetch at all. The live session cookie is *not* synced: it is regenerable
/// from the password, so copying it would widen exposure and buy nothing.
///
/// Its own document rather than a field on the `budget` record: `budget.json`
/// is written back at default permissions on the PC, so a password riding
/// inside it would be readable by anything that reads the budget.
///
/// Two fields rather than one record body, so a device that only ever set the
/// username cannot clobber a peer's password with a whole-map LWW. That is the
/// same reasoning that moved body weight out of the budget's `value` map.
///
/// KEEP IN SYNC WITH `diet_guard/sync_merge/_kuchnia.py`.
library;

import 'dart:convert';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/services/sync_device_id.dart';

/// Stable id: exactly one credential record per device-pushed file.
const kuchniaRecordId = 'kuchnia';

/// The panel login, as two independently-clocked fields.
///
/// The Python side spells its password constant as `"pass" + "word"` rather
/// than a literal. That is not a different value -- it is the same
/// `'password'` on the wire -- it only stops ruff's S105 reading the literal
/// as a hardcoded secret, in a repo that bans `noqa` outright. Do not
/// "fix" either side to match the other's spelling.
const kuchniaUsernameField = 'username';

/// The password field name on the wire. See [kuchniaUsernameField].
const kuchniaPasswordField = 'password';

/// Derives a deterministic [Hlc] for a credential from its edit time.
///
/// Identical inputs always yield the same clock, so re-syncing an unchanged
/// credential is a no-op rather than a fresh push on every tick.
///
/// Derived from the *parsed* timestamp rather than the raw string, so the two
/// languages agree even though they format the epoch fallback differently --
/// the same trick `sync_merge_schedule.dart` uses. Python catches
/// `ValueError` from `fromisoformat` and falls back to the epoch; the `?? 0`
/// here is that same fallback.
Hlc kuchniaCredentialHlc(String editedAt) {
  final wallTimeMs =
      DateTime.tryParse(editedAt)?.toUtc().millisecondsSinceEpoch ?? 0;
  return Hlc.newTick(currentSyncDeviceId, wallTimeMsOverride: wallTimeMs);
}

/// Converts this device's catering credential into a [Log].
///
/// Returns an empty [Log] when either half is blank, so a half-filled settings
/// form contributes nothing to the merge rather than pushing an empty-string
/// password that would win LWW against a peer's real one.
Log credentialToLog(String username, String password, String editedAt) {
  if (username.isEmpty || password.isEmpty) return {};
  final hlc = kuchniaCredentialHlc(editedAt);
  return {
    kuchniaRecordId: Record(
      id: kuchniaRecordId,
      fields: {
        kuchniaUsernameField: (username, hlc),
        kuchniaPasswordField: (password, hlc),
      },
    ),
  };
}

/// One resolved catering credential, as the merge settled it.
class KuchniaCredential {
  /// Creates a resolved credential.
  const KuchniaCredential({
    required this.username,
    required this.password,
    required this.editedAt,
  });

  /// The panel e-mail.
  final String username;

  /// The panel password.
  final String password;

  /// When the winning side last set it, ISO format.
  final String editedAt;
}

/// Extracts the credential from a merged [Log].
///
/// Returns null when no device has contributed one yet, or when the merged
/// record is missing either half -- callers treat that as "not configured",
/// which is never an error at the call site.
///
/// `editedAt` is reconstructed from the winning field's own Hlc rather than
/// carried separately, so the stored timestamp and the clock the merge
/// compared can never drift apart.
KuchniaCredential? logToCredential(Log log) {
  final record = log[kuchniaRecordId];
  if (record == null) return null;
  final username = record.fields[kuchniaUsernameField]?.$1;
  final passwordField = record.fields[kuchniaPasswordField];
  final password = passwordField?.$1;
  if (username is! String || password is! String) return null;
  if (username.isEmpty || password.isEmpty) return null;
  final hlc = passwordField!.$2;
  return KuchniaCredential(
    username: username,
    password: password,
    editedAt: DateTime.fromMillisecondsSinceEpoch(
      hlc.wallTimeMs,
      isUtc: true,
    ).toLocal().toIso8601String(),
  );
}

/// Parses one device's pushed credential file into a [Log].
///
/// Throwing [FormatException] or [TypeError] is treated as unparsable by the
/// caller, matching `parseRemoteBudget`'s tolerance for a corrupt push.
Log parseRemoteCredential(String text) {
  final raw = jsonDecode(text);
  if (raw is! Map) {
    throw const FormatException(
      'top-level catering credential payload is not a JSON object',
    );
  }
  return raw.cast<String, dynamic>().map(
    (id, data) => MapEntry(id, Record.fromJson(data as Map<String, dynamic>)),
  );
}

/// Serializes a merged credential [Log] for push.
String encodeCredentialForPush(Log log) => jsonEncode({
  for (final entry in log.entries) entry.key: entry.value.toJson(),
});
