#!/bin/bash
# ============================================================================
# Diet Guard installer: hidden budget + log-to-unlock gate.
#
# Usage: bash install.sh
#
# What it does:
#   1. Ensures system deps (setxkbmap for VT-disable, requests for OFF lookups)
#   2. Installs + enables the systemd user timer that fires the gate every ~30m
#   3. Seals your daily budget from biometrics (only if not already sealed)
#   4. Locks the budget file immutable with `chattr +i` (the real tamper gate)
# ============================================================================

set -euo pipefail

# Split declare/assign so the command-substitution exit code is not masked (SC2155).
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
readonly SCRIPT_DIR
# python_pkg/diet_guard -> repo root (two levels up).
REPO_DIR="$(readlink -f "$SCRIPT_DIR/../..")"
readonly REPO_DIR
readonly SERVICE_SRC="$SCRIPT_DIR/diet-guard-gate.service"
readonly TIMER_SRC="$SCRIPT_DIR/diet-guard-gate.timer"
readonly SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
readonly DATA_DIR="$HOME/.local/share/diet_guard"
readonly BUDGET_FILE="$DATA_DIR/.budget"

echo "=== Diet Guard Installer ==="

# 1. System dependencies ------------------------------------------------------
echo "[1/4] Checking system dependencies..."
if ! command -v setxkbmap &>/dev/null; then
    echo "  Installing xorg-setxkbmap (gate disables VT switching while locked)..."
    sudo pacman -S --noconfirm xorg-setxkbmap
else
    echo "  setxkbmap present"
fi
if ! python -c 'import requests' 2>/dev/null; then
    echo "  Installing python-requests (Open Food Facts lookups)..."
    sudo pacman -S --noconfirm python-requests
else
    echo "  python-requests present"
fi

# 2. systemd user timer + service --------------------------------------------
echo "[2/4] Installing systemd user timer + service..."
mkdir -p "$SYSTEMD_USER_DIR"
cp "$SERVICE_SRC" "$SYSTEMD_USER_DIR/diet-guard-gate.service"
cp "$TIMER_SRC" "$SYSTEMD_USER_DIR/diet-guard-gate.timer"
systemctl --user daemon-reload
systemctl --user enable --now diet-guard-gate.timer
echo "  Timer enabled and started (fires the gate every ~30 min)."

# 3. Seal the daily budget (hidden) ------------------------------------------
echo "[3/4] Sealing your daily budget..."
if [[ -e "$BUDGET_FILE" ]]; then
    echo "  Budget already sealed at $BUDGET_FILE - skipping init."
else
    echo "  Enter your biometrics (used once then discarded; the value is hidden):"
    (cd "$REPO_DIR" && python -m python_pkg.diet_guard init)
fi

# 4. Lock the budget immutable (the real tamper friction) --------------------
echo "[4/4] Locking the budget file (chattr +i)..."
read -r attrs _ <<<"$(lsattr -d "$BUDGET_FILE" 2>/dev/null || true)"
if [[ "$attrs" == *i* ]]; then
    echo "  Already immutable."
else
    sudo chattr +i "$BUDGET_FILE"
    echo "  Locked. To change it later: sudo chattr -i '$BUDGET_FILE'; re-run init; re-lock."
fi

echo "=== Installation complete ==="
echo "The gate checks every ~30 min (08:00-22:00) and locks until you log a meal"
echo "once you have gone 5h without logging."
echo "Test the lock now (safe, closeable): \
cd $REPO_DIR && python -m python_pkg.diet_guard gate --demo"
