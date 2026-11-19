# Patch-target gate (`scripts/check_patch_targets.py`)

`mock.patch("pkg.module.NAME", ...)` fails open. When a refactor moves `NAME`, the old path still
imports, the patch redirects nothing, and the test stays green while it writes to real user state.
The script reads every test file, finds each literal `patch("<package>....")` target, and exits 1
when a target no longer resolves.

## Usage

Run it from the repo root:

```bash
python3 scripts/check_patch_targets.py PACKAGE [--tests-root DIR]
```

- `PACKAGE` is required. The script checks only targets inside it (`pkg` or `pkg.*`; `pkg_other`
  is not `pkg`). It has no default, because a silent default would check the wrong package and
  pass, which is the fail-open shape the gate exists to catch.
- `--tests-root` defaults to `PACKAGE/tests`.
- The package must be a flat package at the repo root (`./PACKAGE/__init__.py`). There is no
  `src/` layout support yet.
- Exit codes: `0` clean, `1` stale targets (each printed as `file:line: patch target does not
  resolve: ...`), a package that will not import or a missing tests root, `2` usage error.

## Adopting it in another guard repo

Copy `scripts/check_patch_targets.py` into the repo's `scripts/`, then add this hook to
`.pre-commit-config.yaml` under a `repo: local` block:

```yaml
      - id: patch-targets
        name: test patch targets resolve
        entry: python3 scripts/check_patch_targets.py <your_package>
        language: system
        pass_filenames: false
        files: ^<your_package>/
```

The script puts the repo root on `sys.path` itself, so the hook works on a CI runner that never
installed the package.

## Follow-up: a shared copy

Each adopter copies the script today. Moving it to a shared `~/src/utils/patch_targets/` package
is a separate follow-up, done once a second repo actually adopts it.
