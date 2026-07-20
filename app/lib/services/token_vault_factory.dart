/// Platform entry point for the GitHub sync token vault.
library;

export 'token_vault_io.dart'
    if (dart.library.js_interop) 'token_vault_web.dart';
