"""Body sync: wake-alarm weigh-in ingestion, the Log adapter, and the tick."""

from __future__ import annotations

import json
from unittest.mock import MagicMock, patch

from crdt_sync import Hlc, MirrorSyncClient, RemoteSyncError, merge_logs
import pytest

from diet_guard import _sync_body
from diet_guard._body_ingest import fetch_alarm_logs, weight_candidates
from diet_guard._body_store import read_body, set_profile, set_weight, weights
from diet_guard._device import device_id
from diet_guard.sync_merge._body import (
    body_to_log,
    encode_body_for_push,
    log_to_body,
    parse_remote_body,
)

# 2026-09-27 ~21:00 UTC: after that morning's weigh-in, as a real publish is.
_HLC = Hlc(wall_time_ms=1_790_535_000_000, counter=0, node_id="phone").to_str()


def _alarm(latest: object = None, sessions: object = None, hlc: str = _HLC) -> str:
    fields: dict[str, object] = {}
    if latest is not None:
        fields["latest_weight_kg"] = [latest, hlc]
    if sessions is not None:
        fields["morning_sessions"] = [sessions, hlc]
    return json.dumps({"alarm": {"fields": fields}})


def _cell(value: object) -> dict[str, object]:
    """Narrow a document cell (typed ``object``) for indexing."""
    assert isinstance(value, dict)
    return value


class TestWeightCandidates:
    def test_latest_uses_its_hlc_and_sessions_fill_gaps(self) -> None:
        cands = weight_candidates(
            [
                (
                    "phone",
                    _alarm(
                        {"date": "2026-09-27", "kg": 72.6},
                        [
                            {"date": "2026-09-26", "weight_kg": 72.8},
                            {"date": "2026-09-27", "weight_kg": 72.9},
                            {"date": "2026-09-25", "weight_kg": 500},
                            "junk",
                        ],
                    ),
                )
            ]
        )
        by_day = {c.day: c for c in cands}
        assert set(by_day) == {"2026-09-26", "2026-09-27"}
        assert by_day["2026-09-27"].kg == 72.6  # the HLC-stamped value wins
        assert by_day["2026-09-26"].t == "2026-09-26T00:00:00+00:00"

    @pytest.mark.parametrize(
        "raw",
        [
            "not json",
            json.dumps([1]),
            json.dumps({"alarm": {"fields": {"latest_weight_kg": "short"}}}),
            _alarm({"date": "2026-09-27", "kg": True}),
            _alarm({"date": 5, "kg": 70}),
            _alarm({"date": "2026-09-27", "kg": 70}, hlc="bad-hlc"),
        ],
    )
    def test_unusable_logs_offer_nothing(self, raw: str) -> None:
        assert weight_candidates([("phone", raw)]) == []

    def test_newest_stamp_wins_across_devices(self) -> None:
        older = Hlc(wall_time_ms=1_000, counter=0, node_id="a").to_str()
        cands = weight_candidates(
            [
                ("a", _alarm({"date": "2026-09-27", "kg": 70.0}, hlc=older)),
                ("b", _alarm({"date": "2026-09-27", "kg": 71.0})),
            ]
        )
        assert [c.kg for c in cands] == [71.0]


class TestFetchAlarmLogs:
    def test_reads_every_device_and_skips_missing_files(self) -> None:
        store = MagicMock()
        store.list_directory.return_value = ["a", "b"]
        store.get_file_text.side_effect = ["{}", None]
        assert fetch_alarm_logs(store) == [("a", "{}")]

    def test_mirror_reads_the_primary_only(self) -> None:
        mirror = MagicMock(spec=MirrorSyncClient)
        mirror.primary = MagicMock()
        mirror.primary.list_directory.return_value = []
        assert fetch_alarm_logs(mirror) == []
        mirror.primary.list_directory.assert_called_once()

    def test_a_remote_failure_reads_as_nothing(self) -> None:
        store = MagicMock()
        store.list_directory.side_effect = RemoteSyncError("down")
        assert fetch_alarm_logs(store) == []


class TestLogAdapter:
    def test_round_trip_every_section(self) -> None:
        set_profile(birth="2000-05-22", sex="m")
        set_weight("2026-09-27", 72.6, "phone")
        doc = read_body()
        doc["bodyfat"]["2026-09-27"] = {"pct": 16.8, "t": "2026-09-27T10:00:00+02:00"}
        doc["steps"]["2026-09-27"] = {"n": 8000, "t": "2026-09-27T21:00:00+02:00"}
        doc["activity"] = {
            "sessions": [{"day": "2026-09-27"}],
            "t": "2026-09-27T21:00:00+02:00",
        }
        doc["weights"]["junk"] = "not a cell"
        back = log_to_body(parse_remote_body(encode_body_for_push(body_to_log(doc))))
        assert _cell(back["profile"]["sex"])["v"] == "m"
        assert _cell(back["weights"]["2026-09-27"])["kg"] == 72.6
        assert _cell(back["bodyfat"]["2026-09-27"])["pct"] == 16.8
        assert _cell(back["steps"]["2026-09-27"])["n"] == 8000
        assert back["activity"]["sessions"] == [{"day": "2026-09-27"}]
        assert "junk" not in back["weights"]

    def test_empty_doc_is_an_empty_log(self) -> None:
        assert body_to_log(read_body()) == {}
        assert log_to_body({})["weights"] == {}

    def test_malformed_records_are_dropped(self) -> None:
        log = body_to_log(
            {
                "profile": {},
                "weights": {"2026-09-01": {"kg": 1, "t": "x"}},
                "bodyfat": {},
                "steps": {},
                "activity": {"sessions": "not a list"},
            }
        )
        record = log["w:2026-09-01"]
        record.fields["kg"] = ("not a dict", record.fields["kg"][1])
        log["w:2026-09-02"] = type(record)(id="w:2026-09-02", fields={})
        log["activity"] = type(record)(
            id="activity", fields={"sessions": ("x", record.fields["kg"][1])}
        )
        back = log_to_body(log)
        assert back["weights"] == {}
        assert back["activity"] == {}

    def test_non_object_payload_raises(self) -> None:
        with pytest.raises(TypeError):
            parse_remote_body("[1]")

    def test_later_edit_wins_the_merge(self) -> None:
        set_weight("2026-09-27", 72.0)
        mine = body_to_log(read_body())
        doc = read_body()
        doc["weights"]["2026-09-27"] = {
            "kg": 99.0,
            "src": "manual",
            "t": "2000-01-01T00:00:00+00:00",
        }
        merged = merge_logs(mine, body_to_log(doc))
        assert _cell(log_to_body(merged)["weights"]["2026-09-27"])["kg"] == 72.0


class TestSyncBody:
    def _client(self, files: dict[str, str]) -> MagicMock:
        client = MagicMock()
        client.list_directory.return_value = []
        client.get_file_text.side_effect = files.get
        return client

    def test_merges_a_peer_and_pushes(self) -> None:
        peer_doc = read_body()
        peer_doc["weights"]["2026-09-20"] = {
            "kg": 74.0,
            "src": "manual",
            "t": "2026-09-20T08:00:00+02:00",
        }
        path = "diet-guard-sync/devices/peer/body.json"
        client = self._client({path: encode_body_for_push(body_to_log(peer_doc))})
        _sync_body.sync_body(client, ["peer", device_id()])
        assert weights() == {"2026-09-20": 74.0}
        pushed = client.put_file_text.call_args.args
        assert pushed[0] == f"diet-guard-sync/devices/{device_id()}/body.json"

    def test_skips_missing_and_unparsable_peers(self) -> None:
        client = self._client({"diet-guard-sync/devices/bad/body.json": "{oops"})
        _sync_body.sync_body(client, ["bad", "absent"])
        client.put_file_text.assert_not_called()

    def test_ingests_phone_weigh_ins_first(self) -> None:
        client = self._client({})
        with patch.object(
            _sync_body,
            "fetch_alarm_logs",
            return_value=[("p", _alarm({"date": "2026-09-27", "kg": 72.6}))],
        ):
            _sync_body.sync_body(client, [])
        assert weights() == {"2026-09-27": 72.6}
        client.put_file_text.assert_called_once()


class TestPublishActivity:
    def test_no_source_publishes_nothing(self) -> None:
        with patch.object(_sync_body, "set_activity") as publish:
            _sync_body.publish_activity()
        publish.assert_not_called()

    def test_publishes_when_a_source_exists(self) -> None:
        with (
            patch.object(_sync_body, "sources_available", return_value=True),
            patch.object(_sync_body, "collect_sessions", return_value=()),
            patch.object(_sync_body, "set_activity", return_value=True) as publish,
        ):
            _sync_body.publish_activity()
        publish.assert_called_once_with(())
