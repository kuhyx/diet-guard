"""Tests for pruning device directories nothing writes to any more.

This is the one command that *deletes* data on a shared remote, so the tests
lean on the refusals rather than the happy path: a protected id, a peer with a
record no one else has, and ``--apply`` without a backup must each stop it.
"""

from __future__ import annotations

import json
from typing import TYPE_CHECKING
from unittest.mock import MagicMock

from diet_guard import _cli, _cli_prune, _prune_peers
from diet_guard._device import device_id

if TYPE_CHECKING:
    from pathlib import Path

    import pytest


def _client(logs: dict[str, dict[str, object]]) -> MagicMock:
    """Return a client whose devices publish the given record-id maps."""
    client = MagicMock()
    client.list_directory.return_value = list(logs)
    files = {
        f"diet-guard-sync/devices/{dev}/food_log.json": json.dumps(recs)
        for dev, recs in logs.items()
    }
    client.get_file_text.side_effect = files.get
    return client


class TestPlanPrune:
    """Deciding what may go, without touching anything."""

    def test_a_covered_peer_is_prunable(self) -> None:
        """Every record already held by a kept device -> nothing is lost."""
        client = _client({"live": {"r1": {}, "r2": {}}, "dead": {"r1": {}}})

        plan = _prune_peers.plan_prune(client, {"live"})

        assert plan.prunes == ["dead"]
        assert plan.unique_lost == 0

    def test_a_peer_with_a_unique_record_is_kept(self) -> None:
        """One unheld record is enough to disqualify a peer from deletion."""
        client = _client({"live": {"r1": {}}, "hoarder": {"r1": {}, "r9": {}}})

        plan = _prune_peers.plan_prune(client, {"live"})

        assert plan.prunes == []
        assert plan.unique_lost == 1

    def test_legacy_role_ids_are_never_proposed(self) -> None:
        """Dropping one makes every tick re-merge our own pre-migration log."""
        client = _client({"live": {"r1": {}}, "pc": {}, "phone": {}, "desktop": {}})

        plan = _prune_peers.plan_prune(client, {"live"})

        assert plan.prunes == []
        assert set(plan.keeps) >= {"pc", "phone", "desktop"}

    def test_this_device_is_never_proposed(self) -> None:
        client = _client({device_id(): {"r1": {}}, "live": {"r1": {}}})

        plan = _prune_peers.plan_prune(client, {"live"})

        assert device_id() not in plan.prunes

    def test_an_unreadable_peer_log_counts_as_empty(self) -> None:
        """Unparsable is not "unique" -- it must not block an otherwise safe plan."""
        client = _client({"live": {"r1": {}}})
        client.list_directory.return_value = ["live", "broken"]
        client.get_file_text.side_effect = lambda p: (
            "{not json" if "broken" in p else json.dumps({"r1": {}})
        )

        plan = _prune_peers.plan_prune(client, {"live"})

        assert plan.prunes == ["broken"]

    def test_a_peer_that_never_pushed_is_prunable(self) -> None:
        client = _client({"live": {"r1": {}}})
        client.list_directory.return_value = ["live", "empty"]
        client.get_file_text.side_effect = lambda p: (
            None if "empty" in p else json.dumps({"r1": {}})
        )

        plan = _prune_peers.plan_prune(client, {"live"})

        assert plan.prunes == ["empty"]


class TestApply:
    """The destructive half."""

    def test_backup_writes_every_published_path(self, tmp_path: Path) -> None:
        client = MagicMock()
        client.get_file_text.return_value = "{}"

        written = _prune_peers.backup_peers(client, ["dead"], tmp_path)

        assert written == 4  # log, food bank, curated bank, budget
        assert (tmp_path / "dead" / "food_log.json").read_text() == "{}"

    def test_backup_skips_paths_a_device_never_published(self, tmp_path: Path) -> None:
        client = MagicMock()
        client.get_file_text.return_value = None

        assert _prune_peers.backup_peers(client, ["dead"], tmp_path) == 0

    def test_apply_deletes_all_four_paths(self) -> None:
        client = MagicMock()

        assert list(_prune_peers.apply_prune(client, ["dead"])) == ["dead"]
        assert client.delete_file.call_count == 4


class TestCommand:
    """The CLI wrapper, whose defaults are the real safety rail."""

    def _run(
        self,
        monkeypatch: pytest.MonkeyPatch,
        client: MagicMock,
        **kwargs: object,
    ) -> tuple[int, list[str]]:
        monkeypatch.setattr(_prune_peers, "_client_for_run", lambda: client)
        out: list[str] = []
        opts = {"keep": ["live"], "backup_dir": None, "apply": False, **kwargs}
        code = _cli_prune.cmd_prune_peers(out.append, **opts)
        return code, out

    def test_dry_run_deletes_nothing(self, monkeypatch: pytest.MonkeyPatch) -> None:
        client = _client({"live": {"r1": {}}, "dead": {"r1": {}}})

        code, out = self._run(monkeypatch, client)

        assert code == 0
        client.delete_file.assert_not_called()
        assert any("dry run" in line for line in out)

    def test_apply_without_a_backup_dir_refuses(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        client = _client({"live": {"r1": {}}, "dead": {"r1": {}}})

        code, out = self._run(monkeypatch, client, apply=True)

        assert code == 1
        client.delete_file.assert_not_called()
        assert any("refusing to delete" in line for line in out)

    def test_an_unsafe_plan_refuses(self, monkeypatch: pytest.MonkeyPatch) -> None:
        client = _client({"live": {"r1": {}}, "hoarder": {"r1": {}, "r9": {}}})

        code, out = self._run(monkeypatch, client, apply=True)

        assert code == 1
        client.delete_file.assert_not_called()
        assert any("exist only on" in line for line in out)

    def test_nothing_to_prune_is_reported(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        client = _client({"live": {"r1": {}}})

        code, out = self._run(monkeypatch, client)

        assert code == 0
        assert any("nothing to prune" in line for line in out)

    def test_apply_backs_up_then_deletes(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        client = _client({"live": {"r1": {}}, "dead": {"r1": {}}})

        code, out = self._run(monkeypatch, client, apply=True, backup_dir=str(tmp_path))

        assert code == 0
        assert client.delete_file.call_count == 4
        assert any("pruned 1 device" in line for line in out)

    def test_main_dispatches_the_subcommand(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The argparse flags reach the handler unpacked."""
        seen: dict[str, object] = {}

        def _fake(_emit: object, **kwargs: object) -> int:
            seen.update(kwargs)
            return 0

        monkeypatch.setattr(_cli, "cmd_prune_peers", _fake)

        assert _cli.main(["prune-peers", "--keep", "abc"]) == 0
        assert seen == {"keep": ["abc"], "backup_dir": None, "apply": False}
