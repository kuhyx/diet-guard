"""Tests for the curated bank's primary-only read.

Split out of ``test_sync_banks.py`` to keep both files under the repo's
250-line cap.
"""

from __future__ import annotations

from unittest.mock import MagicMock

from crdt_sync import MirrorSyncClient

from diet_guard import _sync_banks


class TestPrimaryOnlyText:
    """Reading the curated bank without the per-peer mirror fallthrough."""

    def test_a_mirrored_client_reads_only_the_primary(self) -> None:
        """The 17s/tick the fallthrough cost was spent fetching ``{}``."""
        primary = MagicMock()
        primary.get_file_text.return_value = None
        mirror = MagicMock()
        client = MirrorSyncClient(primary, mirror)

        assert _sync_banks._primary_only_text(client, "some/path") is None
        mirror.get_file_text.assert_not_called()

    def test_an_unmirrored_client_is_read_directly(self) -> None:
        """GitHub-only devices have no primary/mirror split to skip."""
        client = MagicMock()
        client.get_file_text.return_value = "{}"

        assert _sync_banks._primary_only_text(client, "some/path") == "{}"
        client.get_file_text.assert_called_once_with("some/path")
