# diet_guard

A log-to-unlock gate: locks the desktop until a meal is logged once a meal
slot (08:00 / 12:00 / 16:00 / 20:00) has elapsed without one, and tracks a
sealed daily calorie/macro budget.

## Install

```bash
bash install.sh
```

This installs the package + dependencies into system Python's user
site-packages (the systemd service runs `/usr/bin/python` directly, not a
venv — see `CLAUDE.md`), installs the systemd user timer, seals your daily
budget, and locks the budget file immutable.

## Usage

```bash
python -m diet_guard init          # one-time: compute and seal today's budget
python -m diet_guard gate --demo   # test the lock window (safe, closeable)
```

The timer runs the gate automatically every ~30 minutes; no manual
invocation is needed once installed.

## Development

```bash
python -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/pre-commit install && .venv/bin/pre-commit install --hook-type pre-push
.venv/bin/python -m pytest diet_guard/tests/ --cov=diet_guard --cov-branch --cov-fail-under=100
```

See `CLAUDE.md` for scheduling details and production deployment gotchas,
and `docs/design.md` for the original feature spec.
