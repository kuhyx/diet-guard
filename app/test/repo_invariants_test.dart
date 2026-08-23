/// Structural rules that used to live only as prose in CLAUDE.md.
///
/// Each rule here was previously a paragraph asking a future reader not to do
/// something. A paragraph does not fail a commit, so these are tests instead:
/// the rule and its enforcement are the same artifact, and the *why* lives in
/// the test name rather than in a document that can drift from the code.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `app/` from the repo root, resolved relative to the package directory so
/// the test works regardless of the working directory `flutter test` uses.
Directory get _appDir {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate app/ from ${Directory.current.path}');
    }
    dir = parent;
  }
  return dir;
}

List<File> _dartFilesIn(String relative) {
  final dir = Directory('${_appDir.path}/$relative');
  if (!dir.existsSync()) return const [];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
}

void main() {
  group('the desktop target is a web build, not a GTK embedder', () {
    // Flutter's Linux embedder manages ~20fps at 3840x2160 where the same Dart
    // in Chrome sustains ~144fps. `flutter create --platforms linux` would
    // silently restore the slow path, and nothing about the resulting tree
    // looks wrong at a glance -- so the absence of the directory is asserted.
    test('app/linux/ does not exist', () {
      expect(
        Directory('${_appDir.path}/linux').existsSync(),
        isFalse,
        reason: 'A Linux embedder target was re-added. The desktop app is the '
            'web build served by bin/diet_guard_desktop.dart; see CLAUDE.md.',
      );
    });
  });

  group('dart:io stays behind the platform seam', () {
    // dart:io does not fail a web *compile* -- it becomes a stub that throws at
    // runtime, so the symptom of a bad import is a blank white window rather
    // than a build error. Widget tests run on the VM and would not catch it.
    test('only *_io.dart halves and lib/desktop/ import dart:io', () {
      final offenders = <String>[];
      for (final file in _dartFilesIn('lib')) {
        final relative = file.path.split('/app/lib/').last;
        final isSeam = relative.endsWith('_io.dart');
        final isDesktopOnly = relative.startsWith('desktop/');
        if (isSeam || isDesktopOnly) continue;
        if (file.readAsStringSync().contains("import 'dart:io'")) {
          offenders.add(relative);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'These files import dart:io outside the conditional-export '
            'seam, which compiles for web and throws at runtime (blank white '
            'window). Move the platform edge into a *_io.dart / *_web.dart '
            'pair, and branch on kIsWeb before any Platform.is… check.',
      );
    });
  });

  group('deliberately removed features stay removed', () {
    // The meal builder, "repeat last meal" and the temptation-bundling reward
    // prompt were each removed as unused. Re-adding one is a decision, not an
    // accident -- this test exists so it cannot happen by accident.
    test('no meal builder, repeat-last-meal or reward prompt', () {
      final banned = RegExp(
        r'MealBuilder|mealBuilder|repeatLastMeal|rewardPrompt|temptationBundl',
      );
      final offenders = <String>[];
      for (final file in _dartFilesIn('lib')) {
        if (banned.hasMatch(file.readAsStringSync())) {
          offenders.add(file.path.split('/app/lib/').last);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'A removed feature came back. See the "Do NOT" section of '
            'CLAUDE.md before re-adding any of these.',
      );
    });

    // Photos took image_picker, the blob stores, the wrapper's /blobs/ route
    // and the CAMERA permission with them. Re-adding photos means re-adding
    // all of that *plus* syncing image blobs, since a device-local attachment
    // would violate the one-source-of-truth rule.
    test('no image_picker dependency', () {
      final pubspec = File('${_appDir.path}/pubspec.yaml').readAsStringSync();
      expect(
        pubspec.contains('image_picker'),
        isFalse,
        reason: 'Meal photos were removed deliberately. A device-local image '
            'attachment also breaks the shared-source-of-truth rule.',
      );
    });

    test('no CAMERA permission in the Android manifest', () {
      final manifest = File(
        '${_appDir.path}/android/app/src/main/AndroidManifest.xml',
      );
      expect(
        manifest.readAsStringSync().contains('android.permission.CAMERA'),
        isFalse,
        reason: 'The CAMERA permission came back with no photo feature to '
            'justify it.',
      );
    });
  });

  group('singletons that silently no-op are initialised at startup', () {
    // Every catering entry point checks `isInitialized` first and returns
    // quietly when it is false, so a missing `init()` does not throw -- it
    // reads as "no delivery" and "no credential" forever. That is invisible in
    // widget tests, which initialise these directly, and was caught only by
    // grepping main.dart before a phone deploy.
    test('main.dart initialises the catering services', () {
      final source = File('${_appDir.path}/lib/main.dart').readAsStringSync();
      for (final call in [
        'KuchniaCredentialService.init()',
        'KuchniaQueueService.init()',
      ]) {
        expect(
          source.contains(call),
          isTrue,
          reason: '$call is missing from main(). The feature will silently do '
              'nothing on a real device while every test still passes.',
        );
      }
    });
  });

  group('the desktop wrapper origin is fixed', () {
    // IndexedDB is keyed by origin and lives in the Chrome profile. Changing
    // either the port or the --user-data-dir hides the entire local food log
    // behind a different origin, which reads as data loss to the user.
    test('the wrapper port is still 8732', () {
      final source = File(
        '${_appDir.path}/lib/services/desktop_wrapper.dart',
      ).readAsStringSync();
      expect(
        source.contains('desktopWrapperPort = 8732'),
        isTrue,
        reason: 'The wrapper port changed. IndexedDB is keyed by origin, so a '
            'new port looks like a different app with no history at all. '
            '8730 is ~/todo and 8731 is ~/habit_stack; do not collide.',
      );
    });

    test('the Chrome profile directory is still diet-guard-desktop', () {
      final source = File(
        '${_appDir.path}/bin/diet_guard_desktop.dart',
      ).readAsStringSync();
      expect(
        source.contains("'diet-guard-desktop', 'profile'"),
        isTrue,
        reason: 'The Chrome --user-data-dir moved. IndexedDB lives in that '
            'profile, so relocating it hides the entire local food log.',
      );
    });
  });
}
