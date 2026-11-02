import 'package:diet_guard_app/services/google_sign_in_backend.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('the programmatic Google flow is Android only', () {
    // The plugin's own gate (AccountManager exists only on Android), so
    // desktop keeps the password path visible and never shows a button that
    // cannot succeed.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(googleSignInSupported, isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(googleSignInSupported, isTrue);
  });
}
