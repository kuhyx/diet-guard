/// The catering import's single error type.
///
/// Mirrors `diet_guard/_kuchnia_errors.py`. Every failure the panel can hand
/// back becomes one of these, so the fail-closed boundary in
/// `kuchnia_import.dart` has exactly one exception to translate into a reason
/// string -- a catering outage must never break the caller.
library;

/// Raised when the catering panel cannot be read.
class KuchniaError implements Exception {
  /// Creates an error carrying a user-facing [message].
  const KuchniaError(this.message);

  /// Why the panel could not be read, phrased for display.
  final String message;

  @override
  String toString() => message;
}
