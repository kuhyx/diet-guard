"""Constants for the diet_guard calorie tracker and gate."""

from __future__ import annotations

from pathlib import Path

# --- Daily target -----------------------------------------------------------
# There is deliberately NO budget number here.  Like the home GPS coordinates in
# phone_focus_mode (which live only in the git-ignored config_secrets.sh on the
# device, never in committed source), the real budget is computed once from
# biometrics at ``init`` time and sealed into BUDGET_FILE below.  It is read via
# python_pkg.diet_guard._budget.daily_budget() for over/under decisions only and
# is never printed -- see _budget.py for the full threat model.
#
# Fraction of the budget at which status flips from "on track" to "approaching
# limit".  Surfaced as a label, so the threshold leaks only by boundary-probing.
BUDGET_WARN_FRACTION: float = 0.80

# --- Storage ----------------------------------------------------------------
# The food log is personal and high-churn, so it lives in the XDG data dir and
# is deliberately NOT committed to git (unlike wake_state.json).
DATA_DIR: Path = Path.home() / ".local" / "share" / "diet_guard"
FOOD_LOG_FILE: Path = DATA_DIR / "food_log.json"
# The user's personal "food bank": every food they have logged before, with its
# full macros, keyed by name.  This is the ONLY corpus the gate's autocomplete
# searches -- Open Food Facts is used to *fill* a new food's macros, never to
# search.  Local-only, git-ignored.
FOOD_BANK_FILE: Path = DATA_DIR / "food_bank.json"
# The sealed budget: a dotfile alongside the log, base64-wrapped + HMAC-signed,
# made immutable with ``chattr +i``.  Git-ignored, never committed.  "Hidden"
# here means never-online (it lives outside the repo) -- the number is still
# shown freely in local CLI/GUI output; the seal only makes *cheating* hard.
BUDGET_FILE: Path = DATA_DIR / ".budget"

# --- Estimator (Open Food Facts) -------------------------------------------
# The default backend is Open Food Facts' "Search-a-licious" full-text search:
# free, no key, strongest for branded/packaged foods (including fast food).
# (The older cgi/search.pl endpoint is heavily rate-limited and returns an HTML
# "temporarily unavailable" page to API clients, and /api/v2/search ignores the
# query term, so neither is usable here.)  Swappable for a local/remote LLM
# backend later without touching the log or CLI layers.
OFF_SEARCH_URL: str = "https://search.openfoodfacts.org/search"
OFF_TIMEOUT_SECONDS: float = 8.0
OFF_PAGE_SIZE: int = 5
# Open Food Facts asks API clients to identify themselves with a descriptive
# User-Agent string so abusive clients can be told apart from polite ones.
OFF_USER_AGENT: str = "diet_guard/1.0 (personal diet tracker)"
# Portion assumed when neither --grams nor an OFF serving size is available.
DEFAULT_PORTION_GRAMS: float = 100.0

# --- Gate (log-to-unlock) ---------------------------------------------------
# The gate is driven by FIXED MEAL SLOTS, not by a gap timer.  Starting at the
# day-start hour, a slot opens every interval; once a slot's hour has passed,
# that slot must carry a logged meal or the screen locks until it does.  This
# makes tracking fully automatic (you are prompted on a schedule rather than
# trusted to log voluntarily) and nudges regular eating.  Coming home late
# naturally produces several unlogged elapsed slots at once -> one lock that
# backfills the whole day, which is the "requirement to access the PC" behavior.
GATE_DAY_START_HOUR: int = 8  # first slot (08:00); also the "beginning of day"
GATE_SLOT_INTERVAL_HOURS: int = 4  # slots at 08:00, 12:00, 16:00, 20:00
# Past this hour the gate never fires, so an unlogged late slot lapses quietly
# instead of locking you out overnight.  (A new day resets all slots at 00:00.)
GATE_EATING_END_HOUR: int = 22  # exclusive (22:00)
# flock single-instance guard: stops a timer from stacking lock windows.
GATE_LOCK_FILE: Path = DATA_DIR / ".gate.lock"
