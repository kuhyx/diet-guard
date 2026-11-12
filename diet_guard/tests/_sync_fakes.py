"""Shared fakes for the sync tests.

Not a ``test_`` module: these are fixtures-by-hand imported by
``test_sync.py``, ``test_sync_banks.py`` and ``test_sync_pull.py``, and
pytest must not collect them as tests. The repo already excludes this
naming pattern from the ``name-tests-test`` hook.
"""

from __future__ import annotations

import json
from unittest.mock import MagicMock

from diet_guard import _sync_client
from diet_guard._estimator import Nutrition
from diet_guard.sync_merge import budget_to_log


def _remote_budget_json(*, kcal: int, t: str, weight_kg: float | None = None) -> str:
    """Build the wire text a remote device would push for a given budget edit."""
    record: dict[str, object] = {"v": 2, "b": kcal, "t": t}
    if weight_kg is not None:
        record["w"] = weight_kg
    log = budget_to_log(record)
    return json.dumps({rid: rec.to_dict() for rid, rec in log.items()}, indent=2)


def _nutrition(kcal: float = 200.0) -> Nutrition:
    return Nutrition(
        kcal=kcal,
        protein_g=10.0,
        carbs_g=20.0,
        fat_g=5.0,
        grams=100.0,
        source="manual",
    )


def _write_token(token: str = "fake-token") -> None:
    _sync_client.SYNC_TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    _sync_client.SYNC_TOKEN_FILE.write_text(token)


def _mock_client(
    *,
    devices: tuple[str, ...] = (),
    files: dict[str, str] | None = None,
) -> MagicMock:
    """Build a mock ``GitHubSyncClient`` covering the methods sync calls."""
    client = MagicMock()
    client.list_directory.return_value = list(devices)
    resolved_files = files or {}
    client.get_file_text.side_effect = resolved_files.get
    # The real GitHubSyncClient has no bulk-map read, and a MagicMock would
    # otherwise auto-create one returning a Mock -- which then fails to
    # serialise. Deleting it also exercises the documented degrade path:
    # no revision map means every peer is fetched, exactly as before.
    del client.get_string_map
    return client


#: Paths only the end-to-end encryption touches: the two headers, and the
#: old plaintext prefixes the one-time copy reads.
_E2E_BOOKKEEPING = ("diet-guard-sync/e2e", "wake-alarm-sync/e2e")
_OLD_PREFIXES = ("diet-guard-sync/devices/", "wake-alarm-sync/devices/")


def _data_paths(method: MagicMock) -> list[str]:
    """The paths ``method`` was called with, minus E2E header/copy traffic."""
    return [
        call.args[0]
        for call in method.call_args_list
        if call.args[0] not in _E2E_BOOKKEEPING
        and not call.args[0].startswith(_OLD_PREFIXES)
        and call.args[0] not in {"diet-guard-sync/devices", "wake-alarm-sync/devices"}
    ]


class DictStore:
    """In-memory ``RemoteStore``: paths are keys, directories are derived."""

    def __init__(self, files: dict[str, str] | None = None) -> None:
        """Start with ``files`` (path -> text)."""
        self.files = dict(files or {})
        self.puts: list[str] = []

    def list_directory(self, path: str) -> list[str]:
        """Immediate children of ``path``."""
        prefix = f"{path}/"
        return sorted(
            {
                k[len(prefix) :].split("/", 1)[0]
                for k in self.files
                if k.startswith(prefix)
            }
        )

    def get_file_text(self, path: str) -> str | None:
        """The stored text, or None."""
        return self.files.get(path)

    def put_file_text(self, path: str, text: str, *, message: str) -> None:
        """Store ``text`` and record the write."""
        del message
        self.files[path] = text
        self.puts.append(path)

    def get_string_map(self, path: str) -> dict[str, str]:
        """Leaf children of ``path`` with their text."""
        prefix = f"{path}/"
        return {
            k[len(prefix) :]: v
            for k, v in self.files.items()
            if k.startswith(prefix) and "/" not in k[len(prefix) :]
        }

    def delete_file(self, path: str, *, message: str = "") -> None:
        """Forget ``path``."""
        del message
        self.files.pop(path, None)

    def can_access_remote(self) -> bool:
        """Always reachable."""
        return True
