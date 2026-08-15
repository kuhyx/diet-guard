// Shared fixtures for the sync_service test siblings.
//
// Split out of `sync_service_test.dart` for the repo's 250-line cap: these
// helpers are ~100 lines that both siblings need, so duplicating them per
// file would put each back over the cap on its own.
//
// The names are public because they now cross a file boundary; a `_` prefix
// is library-private in Dart, so the siblings could not see them.

// Mirrors `test_sync.py`'s `TestRunSync` and `TestSyncBudget` cases
// (own-id-skip, no-prior-push, non-object payload, corrupt JSON, remote
// merge, food bank rebuild, budget last-writer-wins), plus one Dart-specific
// that has no PC-side equivalent.

import 'dart:convert';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/services/sync_merge.dart';
import 'package:diet_guard_app/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Builds the wire text a remote device would push for a given budget edit.
String remoteBudgetJson({required int kcal, required String t}) {
  final record = <String, dynamic>{'v': 2, 'b': kcal, 't': t};
  final log = budgetToLog(record);
  return jsonEncode({
    for (final entry in log.entries) entry.key: entry.value.toJson(),
  });
}

/// A plain manual-source nutrition value used across the sync fixtures.
const manualNutrition = Nutrition(
  kcal: 200,
  proteinG: 10,
  carbsG: 20,
  fatG: 5,
  grams: 100,
  source: 'manual',
);

/// A tiny in-memory stand-in for the GitHub Contents API, scoped to exactly
/// the calls [runSync] makes via crdt_sync's [GitHubClient]: list `devices`,
/// get a device's file text (which crdt_sync also uses internally to
/// resolve this device's own existing sha before a push), and put this
/// device's file text.
class FakeGitHub {
  FakeGitHub({this.deviceDirs = const [], Map<String, String>? files})
    : files = {...?files};

  final List<String> deviceDirs;
  final Map<String, String> files;

  /// Every `diet-guard-sync/devices/<id>/food_log.json` path this fake
  /// actually served a file-content GET for.
  final List<String> fileGets = [];

  /// Every PUT this fake received, decoded.
  final List<Map<String, dynamic>> puts = [];

  /// Same PUTs, keyed by the repo-relative path they targeted -- lets a
  /// test pick out the food-log push from the budget push, now that a
  /// sync tick does both.
  final Map<String, Map<String, dynamic>> putsByPath = {};

  GitHubClient buildClient() => GitHubClient(
    owner: 'o',
    repo: 'r',
    token: 't',
    httpClient: MockClient(_handle),
  );

  Future<http.Response> _handle(http.Request req) async {
    if (req.url.path == '/repos/o/r') {
      // Repo-existence probe: crdt_sync's GitHubClient calls this to
      // disambiguate "path unused yet" (still 404, but a real repo) from
      // "repo missing/inaccessible" whenever a content-path GET 404s.
      return http.Response('{}', 200);
    }
    final path = req.url.path.replaceFirst('/repos/o/r/contents/', '');
    if (req.method == 'PUT') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      puts.add(body);
      putsByPath[path] = body;
      return http.Response('{}', 200);
    }
    if (path == 'diet-guard-sync/devices') {
      return http.Response(
        jsonEncode([
          for (final d in deviceDirs)
            {
              'type': 'dir',
              'name': d,
              'path': 'diet-guard-sync/devices/$d',
              'sha': 'd-$d',
            },
        ]),
        200,
      );
    }
    if (!files.containsKey(path)) return http.Response('', 404);
    fileGets.add(path);
    final content = base64.encode(utf8.encode(files[path]!));
    // Real GitHub always returns `sha` alongside `content` for a
    // get-file-contents call -- crdt_sync's GitHubClient reads it back to
    // resolve this device's own existing sha before a push.
    final segments = path.split('/');
    final sha =
        segments.length == 4 &&
            segments[0] == 'diet-guard-sync' &&
            segments[1] == 'devices'
        ? 'f-${segments[2]}'
        : null;
    return http.Response(
      jsonEncode({'content': content, 'sha': ?sha}),
      200,
    );
  }
}
