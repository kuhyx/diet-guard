#!/bin/bash
# ============================================================================
# Deploy main everywhere it runs on this PC, then prove it.
#
#   1. Pull the durable clone the gate timer runs from (editable install).
#   2. Reinstall it into system Python's user site: diet-guard-gate.service
#      runs /usr/bin/python, not a venv (CLAUDE.md, the 2026-06-19 outage).
#   3. Rebuild and reinstall the desktop app package (app/install_arch.sh).
#
# The phone APK ships through CI (release-apk.yml) and phone_deploy.sh.
# Idempotent; exits non-zero unless every health check passes.
# ============================================================================

set -euo pipefail

readonly REPO="$HOME/src/diet-guard"
readonly PY=/usr/bin/python3

fail() {
    echo "deploy: $*" >&2
    exit 1
}

git -C "$REPO" pull --ff-only
"$PY" -m pip install --user --break-system-packages -q -e "$REPO"
(cd "$REPO/app" && bash install_arch.sh)

# Health: the gate's own interpreter imports the code the timer will run...
"$PY" -c 'import diet_guard._cli, diet_guard._errors, diet_guard._gatelock' \
    || fail "system python cannot import the gate"
systemctl --user is-enabled --quiet diet-guard-gate.timer \
    || fail "diet-guard-gate.timer is not enabled"
# ...and the desktop package is the version this checkout builds.
want="$(sed -n 's/^version:[[:space:]]*\([^+]*\).*/\1/p' "$REPO/app/pubspec.yaml")"
have="$(pacman -Q diet-guard-app | awk '{print $2}')"
[[ "$have" == "$want-1" ]] || fail "desktop app is $have, want $want-1"
echo "deploy: ok (gate imports, timer enabled, desktop app $have)"
