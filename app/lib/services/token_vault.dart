/// Where the GitHub sync token lives, per platform.
library;

/// Reads and writes the GitHub sync token.
///
/// Two very different implementations sit behind this:
///
/// * Android keeps the token in the OS keystore via `flutter_secure_storage`
///   (`token_vault_io.dart`), migrating any legacy plaintext copy.
/// * The desktop web build never holds the token at all: the wrapper owns it
///   on disk and attaches it to proxied requests, so the vault only reports
///   *whether* one exists (`token_vault_web.dart`).
abstract class TokenVault {
  /// Returns the token, or the empty string when none is stored.
  ///
  /// On web this returns [wrapperManagedToken] as a stand-in whenever the
  /// wrapper holds a token: callers only ever test it for emptiness or hand
  /// it to a client whose requests are proxied, and the real value stays out
  /// of the browser.
  Future<String> read();

  /// Stores [token] (clearing it when empty). Returns false when the platform
  /// has nowhere secure to put it, so the caller can fall back.
  Future<bool> write(String token);

  /// True when this platform can show the token back to the user.
  ///
  /// False on web -- the settings screen hides the PAT field rather than
  /// displaying a placeholder that cannot be edited meaningfully.
  bool get exposesTokenValue;
}

/// Stand-in value used on web in place of the real, wrapper-held token.
const wrapperManagedToken = 'wrapper-managed';
