# Releasing

Releases are built by GitHub Actions (`.github/workflows/release.yml`).

```bash
git tag v0.2.0 && git push origin v0.2.0
```

Pushing a `v*.*.*` tag builds everything and publishes a GitHub release with generated notes, `SHA256SUMS.txt` and build-provenance attestations. "Run workflow" on the Actions tab builds the same files as downloadable artifacts without publishing.

## What a release contains

| File | What it is | Status |
| --- | --- | --- |
| `DevCacheClean-<v>-macos-arm64.dmg` | The macOS app (Apple silicon) | Ad-hoc signed, **not notarized**: on first launch right-click > Open, or run `xattr -dr com.apple.quarantine /Applications/DevCacheClean.app` |
| `dev-cache-clean-<v>-macos-arm64.tar.gz` | Command-line tool, macOS | Same walker as the app |
| `dev-cache-clean-<v>-x86_64-linux-musl.tar.gz`, `…-aarch64-linux-musl.tar.gz` | Command-line tool, Linux (static) | Experimental |
| `dev-cache-clean-<v>-x86_64-windows-gnu.zip`, `…-aarch64-windows-gnu.zip` | Command-line tool, Windows | Experimental |

## Platform support, honestly

- The **app** (window, menu bar, Docker and System tabs) exists only for macOS. There is no Windows or Linux GUI yet.
- On Linux and Windows only the `scan` and `docker` commands exist. They use a portable, single-threaded walker that reports apparent file sizes (not allocated bytes) and is much slower than the macOS walker. `global` (the catalog of tool locations) is macOS-only for now because its paths are macOS paths.
- CI builds all targets and smoke-tests the Linux x86_64 and Windows x86_64 binaries on real runners (`ci.yml`). The ARM targets are only cross-compiled.
- Intel Macs are not built yet.

## Notarization (not set up)

A notarized app needs an Apple Developer account, which is a paid membership and has to come from the maintainer. Without it macOS shows a Gatekeeper warning on first launch. When an account exists, add to `release.yml`: import the Developer ID certificate into a temporary keychain from a secret, sign with `codesign --options runtime --timestamp`, submit with `xcrun notarytool submit --wait`, and `xcrun stapler staple` the DMG. Keep the credentials in repository secrets, never in the repo.

## Before tagging

- `./test-incremental.sh` passes locally.
- The CI badge on `main` is green.
- README and `docs/` describe what the build really does.
