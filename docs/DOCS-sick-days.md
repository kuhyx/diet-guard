# Free days and sick days

`_gate.due_slots` returns `()` on a shared free day (`freedays`) or a sick day
(`sickdays` 0.1.0, one pool for every gate). Nothing is due, so no lock opens,
nothing is said about missing meals and no debt accrues. Logging a meal works
as on any other day (the log path never consults the gate); diet-guard earns
nothing, so there is nothing to credit.

- Each pool is one local file, never the network, so the systemd-fired gate
  cannot hang on it.
- **Fail closed:** an unreadable pool reads as "not free" / "not sick", so the
  gate stays armed. `sickdays.is_sick_day` never raises.
- Only the calendar day of `now` is asked (the last slot is at most 22:00, so
  the gate never runs on yesterday's slots after midnight).
- Tests: `tests/_state_redirects.py` points both pools into `tmp_path`; a real
  sick day on the dev machine must not stand the suite's gate down.
- **Phone gap:** the companion app does not read either pool.
  `due_slot_check.dart` (`checkAndNotify`) still posts "log your meal"
  notifications on a free or sick day. It would need `crdt_sync_dart` syncing
  `sickdays-sync/devices/*/sick_days.json` (see the sickdays README) and an
  early return before `_reconcileNotifications` that cancels pending ones.
