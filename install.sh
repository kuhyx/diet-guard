#!/bin/bash
# ============================================================================
# Diet Guard installer: hidden budget + log-to-unlock gate.
#
# Usage: bash install.sh
#
# What it does:
#   1. Ensures system deps (setxkbmap for VT-disable, requests for OFF lookups)
#   2. pip-installs this package + gatelock into system Python's user
#      site-packages (the systemd service runs /usr/bin/python directly, not
#      a venv, so the package must live where that interpreter can find it —
#      see CLAUDE.md's "Production dependency installation" section)
#   3. Installs + enables the systemd user timer that fires the gate every ~30m
#   4. Seals your daily budget from biometrics (only if not already sealed)
#   5. Locks the budget file immutable with `chattr +i` (the real tamper gate)
# ============================================================================

set -euo pipefail

# Split declare/assign so the command-substitution exit code is not masked (SC2155).
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
readonly SCRIPT_DIR
readonly REPO_DIR="$SCRIPT_DIR"
readonly SERVICE_SRC="$SCRIPT_DIR/diet-guard-gate.service"
readonly TIMER_SRC="$SCRIPT_DIR/diet-guard-gate.timer"
readonly SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
readonly DATA_DIR="$HOME/.local/share/diet_guard"
readonly BUDGET_FILE="$DATA_DIR/.budget"

echo "=== Diet Guard Installer ==="

# 1. System dependencies ------------------------------------------------------
echo "[1/5] Checking system dependencies..."
if ! command -v setxkbmap &>/dev/null; then
    echo "  Installing xorg-setxkbmap (gate disables VT switching while locked)..."
    sudo pacman -S --noconfirm xorg-setxkbmap
else
    echo "  setxkbmap present"
fi

# 2. Install this package + its dependencies into system Python -------------
echo "[2/5] Installing diet_guard + dependencies for /usr/bin/python..."
/usr/bin/python3 -m pip install --user --break-system-packages -e "$REPO_DIR"
echo "  Installed. Verifying import..."
/usr/bin/python3 -c "import diet_guard; import gatelock" \
    && echo "  diet_guard and gatelock import cleanly from the system interpreter."

# 3. systemd user timer + service --------------------------------------------
echo "[3/5] Installing systemd user timer + service..."
mkdir -p "$SYSTEMD_USER_DIR"
cp "$SERVICE_SRC" "$SYSTEMD_USER_DIR/diet-guard-gate.service"
cp "$TIMER_SRC" "$SYSTEMD_USER_DIR/diet-guard-gate.timer"
systemctl --user daemon-reload
systemctl --user enable --now diet-guard-gate.timer
echo "  Timer enabled and started (fires the gate every ~30 min)."

# 4. Seal the daily budget (hidden) ------------------------------------------
echo "[4/5] Sealing your daily budget..."
if [[ -e "$BUDGET_FILE" ]]; then
    echo "  Budget already sealed at $BUDGET_FILE - skipping init."
else
    echo "  Enter your biometrics (used once then discarded; the value is hidden):"
    python -m diet_guard init
fi

# 5. Lock the budget immutable (the real tamper friction) --------------------
echo "[5/5] Locking the budget file (chattr +i)..."
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
echo "Test the lock now (safe, closeable): python -m diet_guard gate --demo"
