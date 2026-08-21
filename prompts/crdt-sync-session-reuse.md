# Session prompt: connection pooling in crdt_sync

Paste everything below the line into a fresh Claude Code session started in
`~/utils` (that is where the library lives — **not** `~/diet-guard`).

---

Add HTTP connection pooling to the shared `crdt_sync` library at
`~/utils/crdt-sync`, then bump the tag and re-pin `~/diet-guard` to it.

## Why

Every HTTP call in `crdt_sync` goes through module-level `requests.get` /
`requests.put` / `requests.post` / `requests.delete`, so each one pays a fresh
DNS + TCP + TLS handshake. There is no `requests.Session` anywhere in the
package.

Measured on this machine, 2026-08-21, against the two real backends:

| Host | fresh conn | session reuse | saving |
|---|---|---|---|
| `api.github.com` | 108ms | 26ms | **82ms/req** |
| `kuhy-syncs-…firebasedatabase.app` | 82ms | 32ms | **51ms/req** |

A diet-guard full sync tick currently makes **27 requests** (12 GitHub, 15
Firebase) in **7.6s**, so pooling projects to **~1.7s saved, about 22%**.

Reproduce both numbers before you start and again at the end — the second run
is the acceptance check, and the first guards against the situation having
changed.

## Scope

**In scope**
1. Connection pooling in `~/utils/crdt-sync/crdt_sync/`, across exactly 9 call
   sites in 3 files:
   - `_github.py`: lines ~73, ~84 (get), ~163 (put), ~238 (delete)
   - `_firebase.py`: ~189, ~319 (get), ~254 (put), ~300 (delete)
   - `_firebase_auth.py`: ~290 (post)
2. A `timeout_seconds` keyword on `firebase_client_for` in `_config.py`
   (see "Second fix" below).
3. Tag bump + re-pin `~/diet-guard/pyproject.toml` **and**
   `~/diet-guard/requirements.txt` (both name the tag).

**Out of scope — do not touch**
- The other consumers. `~/screen-locker` is already on `crdt-sync-v0.7.0`;
  `~/leetcode-guard`, `~/build_your_x` and `~/wake-alarm` are on
  `crdt-sync-v0.5.1`. Leave every one of those pins alone and say so in your
  final report.
- `~/diet-guard/diet_guard/_sync*.py` logic. That work is finished and
  committed; this task only re-pins the dependency.

## The constraint that decides the design

**16 tests patch the module attribute**, e.g.
`patch.object(fb.requests, "get", return_value=...)`:

- `crdt_sync/tests/test_firebase.py` — 8
- `crdt_sync/tests/test_github.py` — 5
- `crdt_sync/tests/test_firebase_auth.py` — 3

A naive switch to `self._session.get(...)` breaks all 16. Do **not** mass-edit
the tests to preserve an implementation choice — pick an implementation that
keeps `<module>.requests.get` patchable, e.g. a module-level session object
exposed so the existing patch target still resolves, or a thin shim whose
`.get`/`.put`/`.post`/`.delete` the tests can patch unchanged.

Whatever you pick, the test diff should be near-zero. If you find yourself
rewriting many tests, that is the signal the design is wrong, not the tests.

## Second fix, same release

`firebase_client_for` (`_config.py`, ~line 140) accepts no timeout, so
`FirebaseSyncClient` silently uses its 15s per-request default while
`SYNC_TIMEOUT_SECONDS` reaches GitHub only. diet-guard currently works around
this by assigning the private `_timeout_seconds` post-construction, in
`diet_guard/_sync_client.py::_apply_timeout` — read that function, it documents
the whole problem.

Add a `timeout_seconds: float = _DEFAULT_TIMEOUT_SECONDS` keyword and thread it
through. **Leave the diet-guard workaround in place** in this task: it is
guarded by tests and must keep working for anyone still on an older pin. Just
note in your report that it can be simplified in a follow-up.

## Gates (both repos)

- `crdt_sync` requires **100% branch coverage** (`fail_under = 100`,
  `--cov-branch` in its `pyproject.toml`) and lints with `select = ["ALL"]`.
- diet-guard: `python -m pytest diet_guard/tests/ --cov=diet_guard
  --cov-branch --cov-fail-under=100` — currently **830 passing at 100%**.
- `pre-commit run --files <changed>` in whichever repo you touched.
- **The repo blocks `noqa` and `type: ignore` outright** (`no-noqa` hook). Fix
  the underlying issue instead; do not add a suppression, and do not add one to
  the ignore list without asking.
- 250-line cap per file, enforced by a hook.
- `~/diet-guard` has a `no local crdt_sync dependency_override` pre-commit hook
  that exists to stop a local path override leaking into a commit. Do not
  defeat it — re-pin to a real pushed tag.

## Production install path (this has caused a 3-day outage before)

`diet-guard-gate.service` runs `/usr/bin/python`, not a venv. After re-pinning:

```bash
/usr/bin/python3 -m pip install --user --break-system-packages -e ~/diet-guard
/usr/bin/python3 -c "import crdt_sync, sys; print(crdt_sync.__file__)"
```

Verify against `/usr/bin/python3`, **never** the dev venv.

## Watch out

- **Do not run diet-guard's CLI against real data.** State lives in
  `~/.local/share/diet_guard/` (441 log entries, 117 foods). Use the test suite,
  or a redirected data dir. A `_test_guard` will raise
  `RealUserStateWriteError` if a test tries to write there — that is a feature.
- A sync tick **pushes to a shared remote** that the phone also reads. Timing a
  real `run_sync()` is fine (it is idempotent), but do not add throwaway writes.
- `~/utils` is a monorepo holding several packages. Stage narrowly —
  `crdt-sync/` only — and note that `crdt-sync/tool/seed_session.py` is already
  modified and `crdt-sync/firebase-debug.log` is untracked; both predate this
  task, so leave them out of your commit.
- Tag `crdt-sync-v0.7.0` already exists, so the new tag is **v0.8.0**. Note that
  0.7.0 also carries "Let a mirror read survive the primary being down", which
  diet-guard does not have yet — re-pinning picks that up too, so re-run
  diet-guard's suite after the bump rather than assuming only your change landed.

## Done means

1. `crdt_sync` at 100% branch coverage, lint clean, with a near-zero test diff.
2. A pushed `crdt-sync-v0.8.0` tag.
3. `~/diet-guard` re-pinned in both `pyproject.toml` and `requirements.txt`,
   830 tests still green at 100%.
4. Installed into `/usr/bin/python3`'s user site-packages and verified there.
5. A re-measured full tick, reported against the 7.6s / 27-request baseline
   above. State the real number even if it undershoots the projected 1.7s.
