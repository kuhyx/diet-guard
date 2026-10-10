"""The list of state/network redirects ``conftest._isolate_state`` applies.

Split out of ``conftest.py`` to keep it under the 250-line cap. Every on-disk
state path and every network entry point a test could reach is patched here;
a new one missing from this list writes to (or reads from) the live machine.
"""

from __future__ import annotations

from typing import TYPE_CHECKING
from unittest.mock import patch

import freedays

if TYPE_CHECKING:
    from pathlib import Path
    from unittest.mock import _patch


def state_redirects(tmp_path: Path) -> list[_patch[object]]:
    """Every patch that points diet_guard state and network at ``tmp_path``."""
    return [
        # The shared free-day pool lives under ~/.local/share, outside every
        # diet_guard path below. Without this a real free day on the
        # developer's machine would make every "the gate is due" test here
        # fail, for a reason that looks nothing like the cause.
        patch(
            "freedays._api.resolve_paths",
            lambda paths: paths or freedays.Paths.under(tmp_path / "freedays"),
        ),
        patch(
            "diet_guard._budget.BUDGET_FILE",
            tmp_path / ".budget",
        ),
        patch(
            "diet_guard._budget_history.BUDGET_HISTORY_FILE",
            tmp_path / ".budget_history",
        ),
        patch(
            "diet_guard._meal_schedule_store.MEAL_SCHEDULE_FILE",
            tmp_path / ".meal_schedule",
        ),
        patch(
            "diet_guard._state.FOOD_LOG_FILE",
            tmp_path / "food_log.json",
        ),
        patch(
            "diet_guard._foodbank.FOOD_BANK_FILE",
            tmp_path / "food_bank.json",
        ),
        patch(
            "diet_guard._foodbank_manual.MANUAL_BANK_FILE",
            tmp_path / "food_bank_manual.json",
        ),
        patch(
            "diet_guard._gatelock_lockfile.GATE_LOCK_FILE",
            tmp_path / ".gate.lock",
        ),
        patch(
            "diet_guard._sync_client.SYNC_TOKEN_FILE",
            tmp_path / "sync_token",
        ),
        patch(
            "diet_guard._sync.SYNC_STATE_FILE",
            tmp_path / "sync_state.json",
        ),
        # Without this a test that syncs mints a uuid into the REAL
        # ~/.local/share/diet_guard/.device_id, and this machine's live sync
        # identity is decided by whichever test happened to run first.
        patch(
            "diet_guard._device.SYNC_DEVICE_ID_FILE",
            tmp_path / ".device_id",
        ),
        # `run_sync` reads this to decide whether to build a Firebase-primary
        # mirror. On a developer machine the real file exists, so without this
        # every sync test would sign in and push to the live database.
        patch(
            "diet_guard._sync_client.CONFIG_FILE",
            tmp_path / "nonexistent-firebase.json",
        ),
        # Every full tick ends by copying the weight log's newest weigh-in
        # into the budget's `w`. `test_sync_budget` asserts the call; every
        # other sync test keeps the budget record untouched by it.
        patch("diet_guard._sync.refresh_weight_from_log", return_value=None),
        # Logging a meal now publishes immediately (`_sync_events`), so every
        # test that logs one would otherwise open a real connection through a
        # path that has nothing to do with what it is asserting. Patched at the
        # *call sites* rather than on `_sync_events`, so a test that imports
        # `publish_after_log` directly still exercises the real helper.
        patch("diet_guard._cli_log.publish_after_log_detached", return_value=None),
        patch("diet_guard._cli_gate.publish_after_log", return_value=None),
        patch("diet_guard._mcp.publish_after_log", return_value=None),
        patch("diet_guard._cli_body.publish_after_log", return_value=None),
        # The gate's pre-lock refresh is a *second*, independent network
        # entry point (narrow peer-log pull, not the full tick). Without
        # this every test that reaches `_should_lock` hits the real remote.
        patch("diet_guard._cli_gate.pull_peer_logs", return_value=None),
        # The catering credentials and its cached session cookie. Redirected
        # for the same reason as `sync_token`: `_test_guard` raises on any
        # write under the real ~/.config/diet_guard, and a test that logs in
        # would otherwise clobber the live session. Deliberately NOT added to
        # `test_state_redirect._REDIRECTED_CONSTANTS`, matching
        # `SYNC_TOKEN_FILE` -- that check enforces a single naming module,
        # which would forbid the CLI naming the path in its own setup text.
        patch(
            "diet_guard._kuchnia_config.KUCHNIA_CREDENTIALS_FILE",
            tmp_path / "kuchnia_credentials",
        ),
        patch(
            "diet_guard._kuchnia_config.KUCHNIA_SESSION_FILE",
            tmp_path / "kuchnia_session.json",
        ),
        patch(
            "diet_guard._kuchnia_credential_store.KUCHNIA_SYNCED_CREDENTIAL_FILE",
            tmp_path / "kuchnia_synced_credential.json",
        ),
        patch(
            "diet_guard._kuchnia_config.KUCHNIA_LAST_IMPORT_FILE",
            tmp_path / "kuchnia_last_import",
        ),
        # The catering fetch is a third network entry point. Patched at each
        # call site, so a test importing `refresh_delivery` directly still
        # exercises the real helper.
        patch("diet_guard._cli_kuchnia.refresh_delivery", return_value=([], None)),
        # Logging a meal now warms the catering bank on a background
        # thread. Without this every meal-logging test in the suite reaches
        # the live panel.
        patch(
            "diet_guard._cli_log.refresh_delivery_once",
            return_value=([], None),
        ),
        # Logging a meal now warms the catering bank on a background
        # thread. Without this every meal-logging test in the suite reaches
        # the live panel.
        patch(
            "diet_guard._gatelock_delivery.refresh_delivery",
            return_value=([], None),
        ),
        # The gate's "Fill all" button fetches through its own lazy helper.
        patch(
            "diet_guard._gatelock_fillall._refresh_delivery",
            return_value=([], None),
        ),
        # The Body tab's profile, weight log and published workouts.
        patch("diet_guard._body_store.BODY_FILE", tmp_path / "body.json"),
        # Workout sources live outside diet_guard entirely: RunnerUp's WebDAV
        # drop and screen-locker's signed log. Reads, not writes -- but a test
        # reading the real ones is non-deterministic, so both point nowhere.
        patch(
            "diet_guard._activity_sources.RUNNERUP_DIRS",
            (tmp_path / "runnerup",),
        ),
        patch(
            "diet_guard._activity_sources.screen_locker_log_file",
            return_value=None,
        ),
    ]
