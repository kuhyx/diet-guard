/// The catering panel credential, stored locally and synced across devices.
///
/// One source of truth: this service owns the value, sync writes back into it,
/// and the settings screen reads and writes it here. There is no second copy
/// to drift -- notably it is *not* mirrored into `flutter_secure_storage`,
/// because two homes for one value is exactly how a stale password survives a
/// change made on the other device.
///
/// **The password is stored and synced in plaintext.** The rest of the synced
/// state is not encrypted either, so do not describe this as "encrypted like
/// everything else". The user chose it deliberately: the alternative was a
/// phone that cannot fetch the catering menu at all, and the blast radius is a
/// catering menu and a delivery address.
///
/// Mirrors `diet_guard/_kuchnia_credential_store.py`.
library;

import 'dart:convert';

import 'package:diet_guard_app/services/document_store.dart';
import 'package:diet_guard_app/services/document_store_factory.dart';
import 'package:flutter/foundation.dart';

/// Reads and writes the catering panel login.
class KuchniaCredentialService {
  KuchniaCredentialService._(this._store);

  /// Document name this service owns.
  static const documentName = 'kuchnia_credential.json';

  static KuchniaCredentialService? _instance;

  /// Returns the initialized singleton; throws if [init] was not called.
  static KuchniaCredentialService get instance => _instance!;

  /// True once [init] has run, so callers can skip work in widget tests that
  /// never initialise this service.
  static bool get isInitialized => _instance != null;

  final DocumentStore _store;
  String _username = '';
  String _password = '';
  String _editedAt = '';

  /// The panel e-mail, or the empty string when unset.
  static String get username => _instance?._username ?? '';

  /// The panel password, or the empty string when unset.
  static String get password => _instance?._password ?? '';

  /// When the credential was last set, ISO format, or '' when never.
  static String get editedAt => _instance?._editedAt ?? '';

  /// True when both halves are present, i.e. a fetch could be attempted.
  static bool get isConfigured => username.isNotEmpty && password.isNotEmpty;

  /// Initialises the singleton against the platform document store.
  static Future<KuchniaCredentialService> init() async {
    if (_instance != null) return _instance!;
    // Resolving the platform store is a plugin call, not reachable from
    // `flutter test`.
    // coverage:ignore-start
    final service = KuchniaCredentialService._(await openDocumentStore());
    // coverage:ignore-end
    await service._load();
    _instance = service;
    return service;
  }

  /// Initialises from [store] for use in unit tests.
  @visibleForTesting
  static Future<KuchniaCredentialService> initForTesting(
    DocumentStore store,
  ) async {
    final service = KuchniaCredentialService._(store);
    await service._load();
    _instance = service;
    return service;
  }

  /// Resets the singleton so [init] can be called again in tests.
  ///
  /// When [store] is given, reads/writes go there instead of the real platform
  /// store -- and because [init] returns early once an instance exists, this
  /// is also what keeps a test off the path_provider channel. Mirrors
  /// `AppSettingsService.resetForTesting`.
  @visibleForTesting
  static void resetForTesting({DocumentStore? store}) {
    _instance = store == null ? null : KuchniaCredentialService._(store);
  }

  Future<void> _load() async {
    final raw = await _store.read(documentName);
    if (raw == null) return;
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return;
      _username = data['username'] is String ? data['username'] as String : '';
      _password = data['password'] is String ? data['password'] as String : '';
      _editedAt = data['t'] is String ? data['t'] as String : '';
    } on FormatException {
      // Keep the defaults; a corrupt document means "not configured", which is
      // never an error at the call site.
    }
  }

  /// Stores a credential the *user* just entered, stamping it now.
  ///
  /// The stamp is what the cross-device merge compares, so an edit made here
  /// beats an older one from the PC and vice versa.
  Future<void> save(String username, String password) => _persist(
    username.trim(),
    password,
    DateTime.now().toIso8601String(),
  );

  /// Applies a credential the sync merge resolved, keeping its edit time.
  ///
  /// Persists [editedAt] verbatim -- the winning side's real edit time, not
  /// "now" -- so re-syncing an unchanged credential stays idempotent instead
  /// of making this device look like the most recent editor on every tick.
  Future<void> applySynced(
    String username,
    String password,
    String editedAt,
  ) async {
    if (username == _username &&
        password == _password &&
        editedAt == _editedAt) {
      return;
    }
    await _persist(username, password, editedAt);
  }

  Future<void> _persist(
    String username,
    String password,
    String editedAt,
  ) async {
    _username = username;
    _password = password;
    _editedAt = editedAt;
    await _store.write(
      documentName,
      jsonEncode({
        'username': _username,
        'password': _password,
        't': _editedAt,
      }),
    );
  }
}
