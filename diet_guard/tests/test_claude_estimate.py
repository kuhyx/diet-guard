"""``estimate_meal``: the prompt it builds and how every failure maps."""

from __future__ import annotations

import asyncio
import base64
from typing import Any
from unittest.mock import AsyncMock, patch

import pytest

from diet_guard import _claude_sdk
from diet_guard._claude_bank import bank_rows
from diet_guard._claude_estimate import (
    FAILED,
    INVALID,
    TIMEOUT,
    EstimateError,
    estimate_meal,
    estimate_meal_async,
)
from diet_guard._estimator import Nutrition
from diet_guard._foodbank import remember_food

GOOD: dict[str, Any] = {
    "desc": "2 jajka sadzone i kromka chleba",
    "grams": 190,
    "kcal": 410,
    "protein_g": 17.5,
    "carbs_g": 22,
    "fat_g": 26,
}


def _fake(result: object = GOOD) -> AsyncMock:
    return AsyncMock(return_value=result)


def test_text_only_builds_one_text_block_and_returns_the_estimate() -> None:
    """The typed meal is sent as text; no image block; the skill is the prompt."""
    model = _fake()
    with patch("diet_guard._claude_sdk.run_model", model):
        est = estimate_meal("2 jajka sadzone i kromka chleba", None)
    assert est.kcal == 410.0
    prompt, content, schema = model.await_args.args
    assert not prompt.startswith("---")  # the front matter is stripped
    assert "How to estimate" in prompt
    assert [block["type"] for block in content] == ["text"]
    assert "2 jajka sadzone i kromka chleba" in content[0]["text"]
    assert schema["required"]
    assert model.await_args.kwargs == {"budget_s": 45.0}


def test_photo_is_sent_as_a_base64_jpeg_block() -> None:
    """A photo rides as an image content block, the way the tutor sends one."""
    model = _fake()
    with patch("diet_guard._claude_sdk.run_model", model):
        estimate_meal(None, b"\xff\xd8photo")
    content = model.await_args.args[1]
    assert content[0]["text"].startswith("No text.")
    image = content[1]
    assert image["type"] == "image"
    assert image["source"]["media_type"] == "image/jpeg"
    assert base64.b64decode(image["source"]["data"]) == b"\xff\xd8photo"


@pytest.mark.parametrize("text", [None, "", "   "])
def test_nothing_to_estimate_is_a_value_error(text: str | None) -> None:
    """No text and no photo never reaches the model."""
    model = _fake()
    with (
        patch("diet_guard._claude_sdk.run_model", model),
        pytest.raises(ValueError, match="nothing to estimate"),
    ):
        asyncio.run(estimate_meal_async(text, None))
    model.assert_not_awaited()


@pytest.mark.parametrize(
    ("raised", "code"),
    [
        (_claude_sdk.ModelTimeoutError("slow"), TIMEOUT),
        (_claude_sdk.ModelError("no login"), FAILED),
    ],
)
def test_model_errors_map_to_contract_codes(raised: Exception, code: str) -> None:
    """A timeout and any other model failure are distinct error codes."""
    model = AsyncMock(side_effect=raised)
    with (
        patch("diet_guard._claude_sdk.run_model", model),
        pytest.raises(EstimateError) as caught,
    ):
        estimate_meal("banan", None)
    assert caught.value.code == code


def test_invalid_answer_is_estimate_invalid() -> None:
    """A schema-breaking answer is an error, never a logged guess."""
    with (
        patch("diet_guard._claude_sdk.run_model", _fake({"desc": "x"})),
        pytest.raises(EstimateError) as caught,
    ):
        estimate_meal("banan", None)
    assert caught.value.code == INVALID


def test_bank_rows_find_each_part_and_the_staples() -> None:
    """Each part of "a i b" finds its own row; staples ride along; no dupes."""
    jajko = Nutrition(kcal=90, protein_g=6, carbs_g=0.5, fat_g=7, grams=60, source="m")
    chleb = Nutrition(
        kcal=160, protein_g=4.5, carbs_g=21, fat_g=6, grams=70, source="m"
    )
    remember_food("jajko sadzone", jajko)
    remember_food("kromka chleba", chleb)
    rows = bank_rows("jajko sadzone i kromka chleba")
    assert any(row.startswith("jajko sadzone | 60 g | 90 kcal") for row in rows)
    assert any(row.startswith("kromka chleba | 70 g") for row in rows)
    assert len(rows) == len(set(rows))
    assert bank_rows(None)  # photo-only: the staples alone


def test_bank_rows_empty_bank_is_empty() -> None:
    """A fresh install has no rows, and the prompt simply omits the table."""
    assert bank_rows("coś") == []
    model = _fake()
    with patch("diet_guard._claude_sdk.run_model", model):
        estimate_meal("coś", None)
    assert "Food bank" not in model.await_args.args[1][0]["text"]


def test_bank_rows_reach_the_prompt() -> None:
    """A banked food is offered to the model as a row it can scale."""
    banana = Nutrition(
        kcal=105, protein_g=1.3, carbs_g=27, fat_g=0.4, grams=118, source="m"
    )
    remember_food("banan", banana)
    model = _fake()
    with patch("diet_guard._claude_sdk.run_model", model):
        estimate_meal("banan", None)
    text = model.await_args.args[1][0]["text"]
    assert "Food bank" in text
    assert "banan | 118 g | 105 kcal" in text
