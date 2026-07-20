#!/bin/bash
# ============================================================================
# ci_mirror.sh — run the exact CI gates locally before a push can leave.
#
# Why: the installed pre-commit hook only checks *staged* files, and the local
# dev environment already has every dependency installed. CI does neither — it
# runs `pre-commit run --all-files` and installs a fresh environment from
# requirements.txt. That gap is why green-locally repos went red in CI
# (missing runtime deps, --all-files lint debt, order-dependent test flakes).
#
# This script reproduces both CI workflows on the developer machine:
#   1. a venv built ONLY from requirements.txt (mirrors the Tests workflow's
#      `pip install -r requirements.txt`), rebuilt only when requirements.txt
#      changes (hash-gated so day-to-day pushes stay fast);
#   2. `pre-commit run --all-files` (mirrors the pre-commit workflow);
#   3. `python -m pytest` inside that clean venv (mirrors Tests);
#   4. `flutter analyze` + `flutter test` for the companion app in app/.
#
# The app is gated here rather than only by pre-commit because pre-commit has
# no Dart hooks at all: without this, the app's tests were never run by
# anything automatic, and a red app/ could be pushed with a green gate.
#
# Wired as the pre-push hook, so a red result blocks the push before CI ever
# sees it. Escape hatch for genuine emergencies: `git push --no-verify`.
# ============================================================================

set -euo pipefail

# Requirements file may be overridden (e.g. testsAndMisc uses meta/…).
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-requirements.txt}"
readonly REQUIREMENTS_FILE

ROOT="$(git rev-parse --show-toplevel)"
readonly ROOT
cd "$ROOT"

readonly APP_DIR="$ROOT/app"
readonly VENV_DIR="$ROOT/.ci-mirror-venv"
readonly HASH_FILE="$VENV_DIR/.requirements.sha256"
readonly REQ_PATH="$ROOT/$REQUIREMENTS_FILE"

log() { printf 'ci-mirror: %s\n' "$1" >&2; }

fail() {
    log "FAILED — $1"
    log "CI would be red. Fix the above, or 'git push --no-verify' to override."
    exit 1
}

require_file() {
    if [[ ! -f "$REQ_PATH" ]]; then
        fail "requirements file not found: $REQ_PATH"
    fi
}

# Rebuild the venv only when requirements.txt changed since the last build.
ensure_venv() {
    local current stored
    current="$(sha256sum "$REQ_PATH" | cut -d' ' -f1)"
    stored=""
    if [[ -f "$HASH_FILE" ]]; then
        stored="$(cat "$HASH_FILE")"
    fi

    if [[ -x "$VENV_DIR/bin/python" && "$current" == "$stored" ]]; then
        log "venv up to date (requirements.txt unchanged)"
        return
    fi

    log "requirements.txt changed — rebuilding clean venv (mirrors CI install)"
    rm -rf "$VENV_DIR"
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/python" -m pip install --quiet --upgrade pip \
        || fail "pip self-upgrade in the clean venv"
    "$VENV_DIR/bin/python" -m pip install --quiet -r "$REQ_PATH" \
        || fail "pip install -r $REQUIREMENTS_FILE (a dep may be undeclared)"
    printf '%s' "$current" > "$HASH_FILE"
    log "clean venv ready"
}

run_precommit_all_files() {
    log "pre-commit run --all-files (mirrors the pre-commit workflow)"
    pre-commit run --all-files || fail "pre-commit --all-files"
}

run_pytest_clean_venv() {
    log "pytest in the clean venv (mirrors the Tests workflow)"
    "$VENV_DIR/bin/python" -m pytest "$@" || fail "pytest (clean requirements.txt venv)"
}

# Gate the Flutter companion app the same way: analyze (pre-commit has no Dart
# hooks) then the full test suite. Deliberately fails rather than skips when
# flutter is missing -- a gate that quietly passes on a machine without the
# toolchain is the same as no gate.
run_flutter_gates() {
    if [[ ! -f "$APP_DIR/pubspec.yaml" ]]; then
        log "no app/pubspec.yaml — skipping the Flutter gates"
        return
    fi
    if ! command -v flutter >/dev/null 2>&1; then
        fail "flutter is not on PATH but app/ exists (cannot verify the app)"
    fi
    log "flutter analyze (app/)"
    (cd "$APP_DIR" && flutter analyze) || fail "flutter analyze"
    log "flutter test (app/)"
    (cd "$APP_DIR" && flutter test) || fail "flutter test"
}

main() {
    require_file
    ensure_venv
    run_precommit_all_files
    run_pytest_clean_venv "$@"
    run_flutter_gates
    log "all CI gates passed locally — safe to push"
}

main "$@"
