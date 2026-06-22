// Mirrors `test_sync.py`'s `TestRunSync` cases (own-id-skip, no-prior-push,
// non-object payload, corrupt JSON, remote merge, food bank rebuild), plus
// one Dart-specific case for the phone's `imagePath`-preserve-by-id step
// (plan decision 10) that has no PC-side equivalent.

import 'dart:convert';
import 'dart:io';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/github_client.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _manual = Nutrition(
  kcal: 200,
  proteinG: 10,
  carbsG: 20,
  fatG: 5,
  grams: 100,
  source: 'manual',
);

/// A tiny in-memory stand-in for the GitHub Contents API, scoped to exactly
/// the calls [runSync] makes: list `devices`, list a single device's own
/// directory (for its file's sha), get a device's file text, and put this
/// device's file text.
class _FakeGitHub {
  _FakeGitHub({this.deviceDirs = const [], Map<String, String>? files})
    : files = {...?files};

  final List<String> deviceDirs;
  final Map<String, String> files;

  /// Every `devices/<id>/food_log.json` path this fake actually served a
  /// file-content GET for (i.e. a real `getFileText` pull, not a listing).
  final List<String> fileGets = [];

  /// Every PUT this fake received, decoded.
  final List<Map<String, dynamic>> puts = [];

  GitHubClient buildClient() => GitHubClient(
    owner: 'o',
    repo: 'r',
    token: 't',
    httpClient: MockClient(_handle),
  );

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path.replaceFirst('/repos/o/r/contents/', '');
    if (req.method == 'PUT') {
      puts.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response('{}', 200);
    }
    if (path == 'devices') {
      return http.Response(
        jsonEncode([
          for (final d in deviceDirs)
            {'type': 'dir', 'name': d, 'path': 'devices/$d', 'sha': 'd-$d'},
        ]),
        200,
      );
    }
    final segments = path.split('/');
    if (segments.length == 2 && segments[0] == 'devices') {
      final deviceId = segments[1];
      final filePath = 'devices/$deviceId/food_log.json';
      if (!files.containsKey(filePath)) return http.Response('', 404);
      return http.Response(
        jsonEncode([
          {
            'type': 'file',
            'name': 'food_log.json',
            'path': filePath,
            'sha': 'f-$deviceId',
          },
        ]),
        200,
      );
    }
    if (!files.containsKey(path)) return http.Response('', 404);
    fileGets.add(path);
    final content = base64.encode(utf8.encode(files[path]!));
    return http.Response(jsonEncode({'content': content}), 200);
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_sync_test_');
    LogStorageService.resetForTesting(testDir: tempDir);
    FoodBankService.resetForTesting(testDir: tempDir);
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  test('pushes the local log when no other devices have synced', () async {
    await LogStorageService.instance.logMeal('oatmeal', _manual);
    final fake = _FakeGitHub();
    final merged = await runSync(fake.buildClient());

    expect(merged.values.expand((e) => e).length, 1);
    expect(fake.puts, hasLength(1));
  });

  test("skips its own device id ('phone') when listing", () async {
    final fake = _FakeGitHub(
      deviceDirs: const ['pc', 'phone'],
      files: const {'devices/pc/food_log.json': '{}'},
    );
    await runSync(fake.buildClient());
    expect(fake.fileGets, ['devices/pc/food_log.json']);
  });

  test('skips a device with no pushed file yet', () async {
    final fake = _FakeGitHub(deviceDirs: const ['pc']);
    final merged = await runSync(fake.buildClient());
    expect(merged, isEmpty);
  });

  test('ignores a device whose pushed file is not a JSON object', () async {
    final fake = _FakeGitHub(
      deviceDirs: const ['pc'],
      files: const {'devices/pc/food_log.json': '[]'},
    );
    final merged = await runSync(fake.buildClient());
    expect(merged, isEmpty);
  });

  test('skips a device whose pushed file is corrupt json', () async {
    final fake = _FakeGitHub(
      deviceDirs: const ['pc'],
      files: const {'devices/pc/food_log.json': '{not valid json'},
    );
    final merged = await runSync(fake.buildClient());
    expect(merged, isEmpty);
  });

  test("merges in a remote device's entries", () async {
    final remoteLog = jsonEncode({
      '2026-06-22': [
        {
          'id': 'pc-1',
          'time': '2026-06-22T09:00:00+02:00',
          'desc': 'pc meal',
          'kcal': 400.0,
          'protein_g': 20.0,
          'carbs_g': 40.0,
          'fat_g': 10.0,
          'grams': 300.0,
          'source': 'manual',
        },
      ],
    });
    final fake = _FakeGitHub(
      deviceDirs: const ['pc'],
      files: {'devices/pc/food_log.json': remoteLog},
    );
    final merged = await runSync(fake.buildClient());
    final descs = merged.values.expand((e) => e).map((e) => e.desc).toSet();
    expect(descs, contains('pc meal'));
  });

  test('rebuilds the food bank after merge', () async {
    await LogStorageService.instance.logMeal('oatmeal', _manual);
    final fake = _FakeGitHub();
    await runSync(fake.buildClient());

    final bank = await FoodBankService.instance.readBank();
    expect(bank.containsKey('oatmeal'), isTrue);
  });

  test('pushes a payload without imagePath or hmac', () async {
    await LogStorageService.instance.logMeal(
      'oatmeal',
      _manual,
      imagePath: '/local/photo.jpg',
    );
    final fake = _FakeGitHub();
    await runSync(fake.buildClient());

    final pushed = fake.puts.single;
    final pushedText = utf8.decode(base64.decode(pushed['content'] as String));
    expect(pushedText, isNot(contains('imagePath')));
    expect(pushedText, isNot(contains('hmac')));
  });

  test("reuses this device's existing sha when it has pushed before", () async {
    final fake = _FakeGitHub(
      files: const {'devices/phone/food_log.json': '{}'},
    );
    await runSync(fake.buildClient());
    expect(fake.puts.single['sha'], 'f-phone');
  });

  test(
    'preserves a local imagePath even when a remote tombstone wins the merge',
    () async {
      await LogStorageService.instance.writeLog({
        '2026-06-22': [
          const FoodEntry(
            id: 'x',
            time: '2026-06-22T08:00:00',
            desc: 'photo meal',
            grams: 100,
            kcal: 200,
            proteinG: 10,
            carbsG: 20,
            fatG: 5,
            source: 'manual',
            imagePath: '/local/photo.jpg',
          ),
        ],
      });
      final remoteLog = jsonEncode({
        '2026-06-22': [
          {
            'id': 'x',
            'time': '2026-06-22T08:00:00',
            'desc': 'photo meal',
            'kcal': 200.0,
            'protein_g': 10.0,
            'carbs_g': 20.0,
            'fat_g': 5.0,
            'grams': 100.0,
            'source': 'manual',
            'deleted': true,
          },
        ],
      });
      final fake = _FakeGitHub(
        deviceDirs: const ['pc'],
        files: {'devices/pc/food_log.json': remoteLog},
      );
      final merged = await runSync(fake.buildClient());

      final entry = merged.values.expand((e) => e).single;
      expect(entry.deleted, isTrue);
      expect(entry.imagePath, '/local/photo.jpg');
    },
  );
}
