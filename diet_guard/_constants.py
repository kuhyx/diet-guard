"""Constants for the diet_guard calorie tracker and gate."""

from __future__ import annotations

from pathlib import Path

# --- Daily target -----------------------------------------------------------
# There is deliberately NO budget number here.  It is computed once from
# biometrics at ``init`` time, written to BUDGET_FILE below, and freely
# editable and synced afterward from either device -- see _budget.py and
# _sync.py.  Read via diet_guard._budget.daily_budget() for over/under
# decisions; freely shown in local CLI/GUI/app output.
#
# Fraction of the budget at which status flips from "on track" to "approaching
# limit".  Also mirrored above 100% as the day-status yellow/red boundary for
# the calendar -- see _daystatus.py.
BUDGET_WARN_FRACTION: float = 0.80

# --- Storage ----------------------------------------------------------------
# The food log is personal and high-churn, so it lives in the XDG data dir and
# is deliberately NOT committed to git (unlike wake_state.json).
DATA_DIR: Path = Path.home() / ".local" / "share" / "diet_guard"
FOOD_LOG_FILE: Path = DATA_DIR / "food_log.json"

# Revision cache for cross-device sync. Beside the log it describes and
# cleared with it: skipping an unchanged peer is only sound because that
# peer's records are already merged into the local log, so state that outlived
# its log would skip peers whose data had been lost.
SYNC_STATE_FILE: Path = DATA_DIR / "sync_state.json"
# The user's personal "food bank": every food they have logged before, with its
# full macros, keyed by name.  This is the ONLY corpus the gate's autocomplete
# searches -- Open Food Facts is used to *fill* a new food's macros, never to
# search.  Local-only, git-ignored.
FOOD_BANK_FILE: Path = DATA_DIR / "food_bank.json"
# Hand-curated bank entries (see _foodbank_manual.py): foods added without
# ever logging them, so they are NOT derivable from the food log and must
# sync in their own right.  Kept separate from FOOD_BANK_FILE because that
# one is rewritten wholesale on every log write.
MANUAL_BANK_FILE: Path = DATA_DIR / "food_bank_manual.json"
# The budget: a plain JSON dotfile alongside the log, freely editable on this
# device or the phone app and synced between them (see _sync.py).
# Git-ignored, never committed.  "Hidden" here means never-online (it lives
# outside the repo) -- the number itself is shown freely in local CLI/GUI/app
# output.
BUDGET_FILE: Path = DATA_DIR / ".budget"
# The effective-from history of that budget (see _budget_history.py), kept in
# its own file so ``.budget``'s schema stays at v2 and every existing reader
# of it is untouched.  Classifying a *past* day reads this; everything about
# *today* still reads BUDGET_FILE.  Git-ignored, never committed.
BUDGET_HISTORY_FILE: Path = DATA_DIR / ".budget_history"
# The effective-from history of the meal schedule (see _meal_schedule_store.py)
# -- when the user eats their first and last meal, and how many meals fall in
# between.  Forward-only for the same reason as the budget history: switching
# from four meals to five must not retroactively mark every past day as having
# missed a checkpoint.  Git-ignored, never committed.
MEAL_SCHEDULE_FILE: Path = DATA_DIR / ".meal_schedule"

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

# --- Sync (cross-device log merge) ------------------------------------------
# GitHub is used purely as dumb file storage via the REST Contents API (not a
# git clone) -- mirrors ~/todo's sync transport. Each device pushes its own
# full current log as one file under devices/<id>/food_log.json; merging
# happens client-side (see _sync_merge.py), never via git.
SYNC_REPO_OWNER: str = "kuhyx"
SYNC_REPO_NAME: str = "syncs"
# The id this machine pushed under before per-install uuids. The sync reader
# still treats it as this device's own, so the log pushed under it is not
# pulled back and re-merged as a peer's; drop to None once devices/pc/ has
# been reclaimed. See SYNC_DEVICE_ID_FILE.
SYNC_LEGACY_DEVICE_ID: str | None = "pc"
# This device's sync id, minted once and persisted. A fixed "pc" collides the
# moment a second machine takes the same role, and after a reinstall the new
# install would inherit the old one's CRDT identity; a uuid makes both
# impossible by construction. Lives beside the other state, not in ~/.config,
# because losing it means being seen as a brand-new device.
SYNC_DEVICE_ID_FILE: Path = DATA_DIR / ".device_id"
# A fine-grained GitHub PAT, scoped to just SYNC_REPO_NAME's contents.  The
# user creates this once via github.com (see CLAUDE.md) and saves it here,
# mode 600.  Never committed -- this path is outside the repo entirely.
SYNC_TOKEN_FILE: Path = Path.home() / ".config" / "diet_guard" / "sync_token"
SYNC_TIMEOUT_SECONDS: float = 10.0

#: Per-request budget for a pull the user is actively waiting on (the gate's
#: pre-lock refresh and the lock screen's "Fetch from sync" button).
#:
#: Deliberately far below :data:`SYNC_TIMEOUT_SECONDS`: those paths run 1-2
#: requests and must resolve inside a second, whereas the background tick can
#: afford to be patient. The default is worse than it looks -- ``crdt_sync``
#: v0.6.0's ``firebase_client_for`` takes no timeout at all, so Firebase falls
#: back to *15s per request* and one hung session refresh stalls the lock
#: window. The journal records five such refresh failures in five days.
INTERACTIVE_TIMEOUT_SECONDS: float = 2.0

# --- Kuchnia Wikinga catering import -------------------------------------
# The panel is a white-labelled Dietly SPA. Its API is undocumented; the
# endpoint map was recovered from the site's JS bundles and confirmed against
# live responses (see docs/kuchnia-wikinga.md).
KUCHNIA_API_BASE: str = "https://panel.kuchniavikinga.pl/api"
# Sent as the ``company-id`` header. The panel wants the company *name*, not a
# numeric id -- confirmed by its own postSideOrders call passing companyName.
KUCHNIA_COMPANY: str = "kuchniavikinga"
# The panel's own launcher tag for a browser panel session.
KUCHNIA_LAUNCHER_TYPE: str = "BROWSER_PANEL"
# Credentials the user writes by hand, mode 600: e-mail on line 1, password on
# line 2. Nothing in this package ever writes it, exactly as with
# SYNC_TOKEN_FILE, and it acts as a local override that wins over the synced
# copy. Under ~/.config rather than DATA_DIR so it is off the food-log sync
# path -- but note the credential itself DOES travel between devices now, as
# its own document (diet_guard.sync_merge._kuchnia); the phone runs its own
# catering importer and cannot fetch without it.
KUCHNIA_CREDENTIALS_FILE: Path = (
    Path.home() / ".config" / "diet_guard" / "kuchnia_credentials"
)
# The cached SESSION cookie, so a refresh does not re-login every time. This
# one genuinely never leaves the machine: it is regenerable from the password,
# so syncing it would widen exposure and buy nothing.
KUCHNIA_SESSION_FILE: Path = (
    Path.home() / ".config" / "diet_guard" / "kuchnia_session.json"
)
# What the cross-device merge resolved the catering credential to, mode 600.
# Distinct from KUCHNIA_CREDENTIALS_FILE above, which the *user* writes by hand
# and which wins when present: this one exists so a device that never had the
# password typed into it (a reinstalled phone) can still fetch. Under ~/.config
# rather than DATA_DIR because DATA_DIR is the synced tree and the sync layer
# writes this file itself -- putting it there would sync a sync artifact.
KUCHNIA_SYNCED_CREDENTIAL_FILE: Path = (
    Path.home() / ".config" / "diet_guard" / "kuchnia_synced_credential.json"
)
# One ISO date: the last day whose delivery was fetched. Without it the
# gate and the after-log hook would each pay a full auth + 3-request walk
# every time they fire. The curated bank cannot answer this -- it is keyed
# by dish name, and knowing today's names requires the fetch itself.
# Under ~/.config (not DATA_DIR): a per-device rate limit must not sync.
KUCHNIA_LAST_IMPORT_FILE: Path = (
    Path.home() / ".config" / "diet_guard" / "kuchnia_last_import"
)
KUCHNIA_TIMEOUT_SECONDS: float = 8.0
# Whole-walk ceiling. The import is 3-4 sequential requests, so a per-request
# timeout alone would permit ~32s against a slow provider.
KUCHNIA_TOTAL_DEADLINE_SECONDS: float = 12.0
