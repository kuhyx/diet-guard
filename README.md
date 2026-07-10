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

## MCP server

An optional [Model Context Protocol](https://modelcontextprotocol.io) server
lets an MCP client (Claude Code and its subagents) query today's intake and log
meals as typed tools instead of shelling out to the CLI. It runs in its own
venv (`~/.venvs/diet-guard-mcp`) so the `mcp` SDK never touches the
dependency-light system/CLI python path.

Tools:

- `get_status` — today's consumed kcal + macros, the consumption *band*
  (`on track` / `approaching limit` / `OVER BUDGET`, or none when no budget is
  sealed), plus due / logged / current meal slots.
- `list_today` — today's logged meals (description, kcal, macros, source, slot).
- `get_slots` — the day's fixed meal slots and the current one.
- `log_meal(description, grams=, kcal=, protein=, carbs=, fat=, slot=,
  confirm=False)` — **gated write**: with `confirm=False` it previews the
  resolved nutrition and target slot and mutates nothing; only `confirm=True`
  appends the entry. The gate is intrinsic — never add this tool to a
  permission allowlist, since a client's auto-approve mode would otherwise
  bypass the human confirmation.

The read tools deliberately never expose the raw daily budget number (only the
qualitative band), nor the sealed `.budget` file, the shared HMAC key, or the
sync token — the budget stays hidden by design.

Setup:

```bash
bash scripts/setup_mcp.sh   # create the venv and install diet_guard[mcp]
```

Then restart Claude Code in this repo and approve the project MCP server
(registered in `.mcp.json`).

## Development

```bash
python -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/pre-commit install && .venv/bin/pre-commit install --hook-type pre-push
.venv/bin/python -m pytest diet_guard/tests/ --cov=diet_guard --cov-branch --cov-fail-under=100
```

See `CLAUDE.md` for scheduling details and production deployment gotchas,
and `docs/design.md` for the original feature spec.
