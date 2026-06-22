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
#   4. Installs + enables the systemd user timer that syncs the log every ~15m
#      (the sync itself stays unconfigured -- and a no-op -- until you create
#      a sync token; see the reminder this step prints)
#   5. Seals your daily budget from biometrics (only if not already sealed)
#   6. Locks the budget file immutable with `chattr +i` (the real tamper gate)
# ============================================================================

set -euo pipefail

# Split declare/assign so the command-substitution exit code is not masked (SC2155).
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
readonly SCRIPT_DIR
readonly REPO_DIR="$SCRIPT_DIR"
readonly SERVICE_SRC="$SCRIPT_DIR/diet-guard-gate.service"
readonly TIMER_SRC="$SCRIPT_DIR/diet-guard-gate.timer"
readonly SYNC_SERVICE_SRC="$SCRIPT_DIR/diet-guard-sync.service"
readonly SYNC_TIMER_SRC="$SCRIPT_DIR/diet-guard-sync.timer"
readonly SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
readonly DATA_DIR="$HOME/.local/share/diet_guard"
readonly BUDGET_FILE="$DATA_DIR/.budget"
readonly SYNC_TOKEN_FILE="$HOME/.config/diet_guard/sync_token"

echo "=== Diet Guard Installer ==="

# 1. System dependencies ------------------------------------------------------
echo "[1/6] Checking system dependencies..."
if ! command -v setxkbmap &>/dev/null; then
    echo "  Installing xorg-setxkbmap (gate disables VT switching while locked)..."
    sudo pacman -S --noconfirm xorg-setxkbmap
else
    echo "  setxkbmap present"
fi

# 2. Install this package + its dependencies into system Python -------------
echo "[2/6] Installing diet_guard + dependencies for /usr/bin/python..."
/usr/bin/python3 -m pip install --user --break-system-packages -e "$REPO_DIR"
echo "  Installed. Verifying import..."
/usr/bin/python3 -c "import diet_guard; import gatelock" \
    && echo "  diet_guard and gatelock import cleanly from the system interpreter."

# 3. systemd user timer + service (gate) -------------------------------------
echo "[3/6] Installing the gate's systemd user timer + service..."
mkdir -p "$SYSTEMD_USER_DIR"
cp "$SERVICE_SRC" "$SYSTEMD_USER_DIR/diet-guard-gate.service"
cp "$TIMER_SRC" "$SYSTEMD_USER_DIR/diet-guard-gate.timer"
systemctl --user daemon-reload
systemctl --user enable --now diet-guard-gate.timer
echo "  Timer enabled and started (fires the gate every ~30 min)."

# 4. systemd user timer + service (sync) -------------------------------------
echo "[4/6] Installing the sync's systemd user timer + service..."
cp "$SYNC_SERVICE_SRC" "$SYSTEMD_USER_DIR/diet-guard-sync.service"
cp "$SYNC_TIMER_SRC" "$SYSTEMD_USER_DIR/diet-guard-sync.timer"
systemctl --user daemon-reload
systemctl --user enable --now diet-guard-sync.timer
echo "  Timer enabled and started (syncs the log every ~15 min)."
if [[ -e "$SYNC_TOKEN_FILE" ]]; then
    echo "  Sync token already present at $SYNC_TOKEN_FILE."
else
    echo "  No sync token yet at $SYNC_TOKEN_FILE -- sync will no-op (and log a"
    echo "  failure) on every tick until you create a fine-grained GitHub PAT"
    echo "  scoped to the diet-guard-sync repo's contents and save it there,"
    echo "  mode 600: chmod 600 \"$SYNC_TOKEN_FILE\""
fi

# 5. Seal the daily budget (hidden) ------------------------------------------
echo "[5/6] Sealing your daily budget..."
if [[ -e "$BUDGET_FILE" ]]; then
    echo "  Budget already sealed at $BUDGET_FILE - skipping init."
else
    echo "  Enter your biometrics (used once then discarded; the value is hidden):"
    python -m diet_guard init
fi

# 6. Lock the budget immutable (the real tamper friction) --------------------
echo "[6/6] Locking the budget file (chattr +i)..."
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
