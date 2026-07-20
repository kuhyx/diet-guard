/// Wrapper-backed [TokenVault] for the desktop web build.
library;

import 'dart:convert';

import 'package:diet_guard_app/services/desktop_wrapper.dart';
import 'package:diet_guard_app/services/token_vault.dart';
import 'package:http/http.dart' as http;

/// Delegates token storage to the desktop wrapper.
///
/// The browser never holds the token: [read] reports only whether the wrapper
/// has one, and [write] hands a pasted PAT straight through to the wrapper's
/// 600-mode token file. This is deliberately *not* `flutter_secure_storage`'s
/// web backend, which is WebCrypto-wrapped `localStorage` with the wrap key
/// stored beside the ciphertext -- obfuscation, not encryption at rest.
class WrapperTokenVault implements TokenVault {
  /// Creates a vault talking to the wrapper at [baseUrl].
  WrapperTokenVault({this.baseUrl = desktopWrapperOrigin, http.Client? client})
    : _client = client ?? http.Client();

  /// Origin of the desktop wrapper.
  final String baseUrl;

  final http.Client _client;

  @override
  bool get exposesTokenValue => false;

  @override
  Future<String> read() async {
    try {
      final response = await _client.get(
        Uri.parse('$baseUrl${WrapperPaths.github}auth/status'),
      );
      if (response.statusCode != 200) return '';
      final body = jsonDecode(response.body);
      final configured = body is Map && body['configured'] == true;
      return configured ? wrapperManagedToken : '';
    } on Exception {
      // No wrapper running (a plain browser tab): behave as unconfigured
      // rather than failing the whole settings screen.
      return '';
    }
  }

  @override
  Future<bool> write(String token) async {
    // The stand-in is what `read` handed out; writing it back would replace a
    // real token with a literal.
    if (token == wrapperManagedToken) return true;
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl${WrapperPaths.github}auth/token'),
        body: token,
      );
      return response.statusCode == 204;
    } on Exception {
      return false;
    }
  }
}

/// Opens the platform token vault.
TokenVault openTokenVault() => WrapperTokenVault();
