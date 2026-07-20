#!/bin/bash
# Builds the web bundle and launches the diet_guard companion app through the
# desktop wrapper, straight out of the repo (no packaging step).
#
# The desktop app is a Flutter *web* build rather than a Linux embedder build:
# the embedder manages only ~20fps at 4K, while the same Dart code in Chrome
# sustains ~144fps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

log() { echo "==> $*"; }

command -v flutter >/dev/null 2>&1 || {
    echo "flutter is not on PATH" >&2
    exit 1
}

cd "$SCRIPT_DIR"
flutter config --enable-web >/dev/null

log "fetching pub packages"
flutter pub get

log "building the web bundle"
flutter build web --release

log "launching the app"
exec dart run bin/diet_guard_desktop.dart --web-root "$SCRIPT_DIR/build/web"
