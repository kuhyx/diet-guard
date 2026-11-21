# Lock order

When several locks are due at once, gatelock shows the one with the highest
rank first. Each lower lock waits, with no window, until every higher lock has
been cleared. kuhy fixed this order on 2026-11-21:

| Order | Lock | gatelock app | Rank | Repo |
|---|---|---|---|---|
| 1 | workout | screen_locker | 200 | screen-locker |
| 2 | book | book_guard | 175 | book-guard |
| 3 | tutor | tutor_gate | 150 | tutor |
| 4 | diet | diet_guard | 130 | diet-guard |
| 5 | focus | focus_guard | 128 | focus-guard |
| 6 | leetcode | leetcode_guard | 125 | leetcode-guard |

LeetCode goes last. Each rank is a literal in its own repo, not a
`gatelock.RANK_*` constant, so changing one does not need a gatelock release.
Every repo keeps a copy of this file, and its tests fail when its own number
differs from its row here. Change the rank, this table and the copies in the
other repos together.

Not in the table:

- The wake alarm (300) outranks everything.
- The evening chain (`gatelock.evening_chain`) runs its rungs one at a time,
  in the order book, tutor, LeetCode. Its book rung locks at 150, which ties
  the tutor. Ranks only order locks that are due at the same moment.
- All of these lock with a global grab and VT switching disabled, so no
  higher rank is ever a weaker lock. `gatelock/scripts/verify_all_lockers.py`
  checks this order on a private X server.
