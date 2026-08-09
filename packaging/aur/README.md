# AUR packaging

`PKGBUILD` here is the source of truth for the `diet-guard-app` AUR package.
The AUR checkout (`~/aur/diet-guard-app`) is a copy of this file plus a
generated `.SRCINFO`.

## Why the checksum can go stale

`source=` points at the GitHub tarball for tag `v$pkgver`, and `sha256sums`
is the hash of that tarball. A tarball contains this very file, so the
checksum for tag vX cannot be committed *before* vX is tagged. The copy here
is therefore a **template**: after pushing a new tag, run `updpkgsums` in the
AUR checkout to fill in the real hash, and copy the result back here.

## Tagging hazard (read before tagging)

This repo has grafted upstream Flutter SDK history, so the **local** clone
carries hundreds of tags (`flutter-N.N-candidate.N`, `vN.N.N-N.N.pre`, and a
`v1.16.3` that points at a 2020 `[flutter_tools]` commit) that do not belong to
this app. The remote has only a handful.

- **Never run `git push --tags` here.** It would publish all of them.
- Always push one tag explicitly: `git push origin v1.2.3`.
- Resolve the next free version with `git ls-remote --tags origin`, never with
  the local `git tag`.

`v1.0.0` on the remote points at an older commit that predates the LICENSE, so
the first packageable tag was `v1.0.1`.

## Release flow

```bash
# 1. bump `version:` in app/pubspec.yaml, commit, push
# 2. tag and push the SINGLE tag
git tag v1.2.3 && git push origin v1.2.3

# 3. sync + checksum + build + verify
cp packaging/aur/PKGBUILD ~/aur/diet-guard-app/PKGBUILD
cd ~/aur/diet-guard-app
# bump pkgver to match the tag, then:
updpkgsums
makepkg -Cf
namcap ./*.pkg.tar.zst
sudo pacman -U ./diet-guard-app-*.pkg.tar.zst
diet-guard-app   # must print: diet_guard desktop serving on http://localhost:8732

# 4. publish
makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD .SRCINFO && git commit && git push   # branch is `master`
```

## Notes

- The Flutter app lives in `app/`, so the tarball extracts as
  `diet-guard-$pkgver/app/` while `LICENSE` sits at the repo root. `build()`
  and `package()` `cd` into the subdir; the license is installed from an
  absolute `$srcdir` path.
- `StartupWMClass` is `diet_guard_app` (underscores) while the icon name is
  `diet-guard-app` (hyphens). They genuinely differ — the WM class must match
  what Chrome gets from the wrapper's `--class` flag.
- `install_arch.sh` is deliberately **not** wired to this PKGBUILD. That script
  builds the working tree for local development; this one builds a downloaded
  release tarball. Merging them would destroy the dev loop.
- `options=('!strip')` is load-bearing — see the comment in the PKGBUILD.
- Building requires network access (`pub get`, plus a git fetch of the shared
  `crdt_sync` dependency). The tracked `pubspec.lock` pins what gets resolved.
