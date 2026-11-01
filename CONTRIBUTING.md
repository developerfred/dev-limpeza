# Contributing

Thanks for helping. The project is small on purpose.

## Build

Requirements: macOS 15+, Xcode command line tools, **Zig 0.17**.

```bash
./make-app.sh                 # Zig core + SwiftUI app -> app/DevCacheClean.app
open app/DevCacheClean.app
./build.sh                    # CLI only -> zig-out/bin/dev-cache-clean
ZIG=/path/to/zig ./build.sh   # use a specific Zig binary
```

## Ways to help

- **Report a problem** with the [bug report form](https://github.com/developerfred/dev-limpeza/issues/new?template=bug_report.yml). If the app removed something it should not have, say so first: that is the most important kind of report.
- **Fix or add a cache location** with the [catalog form](https://github.com/developerfred/dev-limpeza/issues/new?template=catalog_entry.yml). A path, what it holds, what is lost and a link or `du` output is enough; a pull request is a bonus.
- **Suggest an idea** with the [feature form](https://github.com/developerfred/dev-limpeza/issues/new?template=feature_request.yml).

The pull request template lists what reviewers look for. Keep changes small; one catalog entry is a perfectly good pull request.

## Before you open a pull request

- Run the checks that match what you changed (they run in CI too):
  - `./test-incremental.sh`: an incremental rescan must equal a full scan after real changes.
  - `./test-git.sh`: the git check against real repositories, including one with a hostile config.
- Compare `dev-cache-clean scan <dir>` with `find` (set of caches) and `du -sk` (sizes) on a directory you can spare.
- If you change the catalog, say how you verified the path and what the user loses by removing it.
- Never add anything that deletes without going through the Trash or an explicit confirmation.
- Keep the app offline: no network calls, no telemetry.

## Adding a cache type

Add an entry to `src/targets.zig` with the directory name, the marker file next to it (or `null`), and a label. Document it in `docs/CATALOG.md`.

## Project agents

`.claude/agents/` holds subagents for Claude Code (QA, design, catalog research, performance, safety, docs). They are optional helpers; the rules above apply to everyone.
