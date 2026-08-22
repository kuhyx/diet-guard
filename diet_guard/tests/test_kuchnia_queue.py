"""The catering dish queue must outlive the submit that consumed a dish.

Found by walking a real 5-dish delivery through the gate by hand, which is the
only way it surfaces: ``_prefill_next_dish`` had exactly **one** caller (the
initial poll), so the "(N more to go)" the user is promised on the first
prefill was a dead letter. Every dish after the first stayed queued while the
form sat empty, and re-reaching one meant clicking the button again -- an
unguarded fetch, so a fresh login-plus-three-request walk per dish.

Counting *call sites* is what catches this. Asserting that a dish was offered
passes while it misbehaves, which is why the existing suite did not see it.

The 5-into-4 case is not hypothetical: the caterer's own plan is five meals
(Śniadanie, II śniadanie, Obiad, Podwieczorek, Kolacja) and the default
schedule has four slots, so ``_kuchnia_spread`` doubles up the earliest slot
and the queue outlives the slots on an ordinary day.
"""

from __future__ import annotations

import queue
from typing import TYPE_CHECKING
from unittest.mock import patch

from diet_guard import _gatelock_mealflow
from diet_guard._gatelock_kuchnia import DeliveryResult
from diet_guard.tests.conftest import _nutrition
from diet_guard.tests.test_kuchnia_gate import _deliver, _dish, _Gate

if TYPE_CHECKING:
    from diet_guard._gatelock import MealGate


class TestTheQueueSurvivesASubmit:
    """What ``_finish_slot`` must do once a queued dish has been logged."""

    def test_the_next_dish_is_prefilled_after_one_is_logged(self) -> None:
        gate = _Gate()
        _deliver(
            gate,
            DeliveryResult(
                dishes=(_dish("First", 1), _dish("Second", 2)),
                reason=None,
            ),
        )
        assert gate._descs == ["First"]
        gate._prefill_next_dish("Logged 08:00: 391 kcal")
        assert gate._descs == ["First", "Second"]
        assert not gate._delivery_pending

    def test_the_log_confirmation_survives_the_prefill(self) -> None:
        # Advancing the queue must not swallow what was just logged: that line
        # is the user's only confirmation the meal was actually recorded.
        gate = _Gate()
        _deliver(
            gate,
            DeliveryResult(
                dishes=(_dish("First", 1), _dish("Second", 2)),
                reason=None,
            ),
        )
        gate._prefill_next_dish("Logged 08:00: 391 kcal")
        assert "Logged 08:00: 391 kcal" in gate.last_status
        assert "Loaded: Second" in gate.last_status

    def test_prefilling_without_a_log_line_stays_unprefixed(self) -> None:
        # The button and the autoload pass no ``logged``, so the status must
        # not grow a stray leading separator.
        gate = _Gate()
        _deliver(gate, DeliveryResult(dishes=(_dish("Only"),), reason=None))
        assert gate.last_status.startswith("Loaded: Only")

    def test_an_exhausted_queue_prefills_nothing(self) -> None:
        # The guard that lets ``_finish_slot`` call this unconditionally.
        gate = _Gate()
        gate._delivery_pending = ()
        gate._prefill_next_dish("Logged 20:00: 391 kcal")
        assert gate._descs == []
        assert gate.statuses == []

    def test_a_whole_five_dish_delivery_walks_without_reclicking(self) -> None:
        """Four submits offer four further dishes -- one button click total.

        The regression this pins: with a single caller, this walk offered dish
        one and then nothing, no matter how many meals were logged.
        """
        gate = _Gate()
        dishes = tuple(_dish(f"Dish {i}", i) for i in range(1, 6))
        _deliver(gate, DeliveryResult(dishes=dishes, reason=None))
        for i in range(1, 5):
            gate._prefill_next_dish(f"Logged slot {i}")
        assert gate._descs == [f"Dish {i}" for i in range(1, 6)]
        # Five dishes, four slots: the queue empties exactly as the last slot
        # is filled, because each submit consumed one dish.
        assert not gate._delivery_pending


class TestLeftoverDishesAreReported:
    """A dish the gate never got to offer must not vanish silently."""

    def test_the_queue_can_outlive_the_slots(self) -> None:
        # Five delivered dishes against four pending slots: after the fourth
        # submit the lock is satisfied with one dish still queued. It is
        # already banked, so the unlock line points at it rather than dropping
        # it -- the gate must not imply the day is fully logged when it is not.
        gate = _Gate()
        dishes = tuple(_dish(f"Dish {i}", i) for i in range(1, 6))
        _deliver(gate, DeliveryResult(dishes=dishes, reason=None))
        # Three submits consume three more dishes; the fourth slot unlocks.
        for i in range(1, 4):
            gate._prefill_next_dish(f"Logged slot {i}")
        assert len(gate._delivery_pending) == 1

    def test_a_result_queue_is_cleared_after_the_poll(self) -> None:
        # The poll's own guard: a stray second poll must find None and stop
        # rather than block forever on an empty queue.
        gate = _Gate()
        result: queue.Queue[DeliveryResult] = queue.Queue(maxsize=1)
        result.put(DeliveryResult(dishes=(_dish(),), reason=None))
        gate._delivery_result = result
        gate._poll_delivery()
        assert gate._delivery_result is None


class TestTheGateAdvancesTheQueue:
    """The same two branches, driven through a real ``MealGate``."""

    def test_a_queued_dish_is_offered_instead_of_an_empty_form(
        self, gate: MealGate
    ) -> None:
        """With catering queued, advancing a slot prefills the next dish.

        Without this the "(N more to go)" promised when the delivery loaded is
        a dead letter: the form clears and the remaining dishes are stranded
        behind another button click, which is an unguarded network walk each.
        """
        gate._pending = [8, 12]
        gate._delivery_pending = (_dish("Second course"),)
        with (
            patch.object(_gatelock_mealflow, "log_meal"),
            patch.object(_gatelock_mealflow, "remember_food"),
        ):
            gate._record("apple", _nutrition(95, 100))
        assert not gate._delivery_pending
        assert "Loaded: Second course" in gate._vars.status.get()
        assert "Logged 08:00" in gate._vars.status.get()

    def test_dishes_left_when_the_last_slot_unlocks_are_named(
        self, gate: MealGate
    ) -> None:
        """Five dishes into four slots leaves one queued at unlock time.

        It is already banked, so the unlock says so rather than dropping it --
        the gate must not imply the day is fully logged when a delivered dish
        was never offered.
        """
        gate._delivery_pending = (_dish("Kolacja"),)
        gate._unlock("Logged 20:00: 391 kcal")
        assert "1 more dish delivered" in gate._vars.status.get()
