"""diet_guard: log what you eat, see the daily number, gate the desktop.

The package has three layers, built in order:

* the tracker (this milestone): a low-friction CLI that estimates the
  calories of a free-text meal and appends a tamper-evident entry to a
  per-day log;
* the gate (next): a screen-lock that will not dismiss until a recent meal
  is logged -- the "log-to-unlock" enforcement;
* the escalation (later): a daily report that tightens the other personal
  enforcers (games, PC uptime) when logging is skipped or the budget blown.
"""

from diet_guard import _test_guard

# Under pytest only: hard-fail any write to the user's real state directories.
# A test once destroyed the user's GitHub PAT by running outside the package
# conftest that redirects those paths; this makes that class of accident
# impossible rather than merely discouraged.  See diet_guard/_test_guard.py.
_test_guard.install()
