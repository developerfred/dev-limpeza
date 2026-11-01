# Architecture

Dev Cache Clean has two layers connected by a small C ABI.

```
macos/Sources (SwiftUI)  ──dcc_scan()──▶  src/lib.zig ──▶ src/core.zig ──▶ src/walker.zig
 menu bar + window + Docker tab           JSON in/out       scan + sort       parallel getattrlistbulk
```

## Zig core (`src/`)

| File | Role |
| --- | --- |
| `targets.zig` | What counts as a cache (`node_modules`, `target`, `.venv`, ...), the marker file that proves it (e.g. `package.json` next to `node_modules`), directories never entered, and the maximum depth (8). |
| `walker.zig` | Picks the implementation at compile time: `walker_macos.zig` on macOS, `walker_portable.zig` elsewhere (single-threaded, apparent sizes, no `global`). The macOS one is one pool of threads (one per CPU) that both discovers caches and sizes them. Each directory is read with a single `getattrlistbulk` call that returns names, types, modification times and allocated sizes, so checking a marker file or a project's last activity costs no extra system calls. Discovery and sizing overlap. macOS only. |
| `core.zig` | `scanAll(root)`: runs the walker, converts the result, sorts by size. `idleDays` is the age of the newest file in the project that owns the cache. |
| `lib.zig` | C ABI used by the app: `dcc_scan(root)` returns a malloc'd JSON array, `dcc_free` releases it. |
| `main.zig` | Command-line front end (`scan`, `docker`). |

Sizes are **allocated bytes on disk**, not apparent size, because that is what removal frees. Symbolic links are never followed.

The library does no deletion on purpose. Cleanup is the app's job so it can always go through the Trash.

### Why `dcc.o` and not a static library

Apple's linker rejects archives written by Zig (members are not 8-byte aligned), so `build.sh` emits a plain object file and `make-app.sh` links it into the Swift executable.

## macOS app (`macos/Sources/`)

- `Model.swift` — scan state, selection, Trash cleanup, periodic rescan (every 6 h) and the stale-cache notification (at most once per 24 h, only above 1 GiB). The blocking C call runs on a dedicated thread with a 16 MB stack.
- `Docker.swift` / `DockerView.swift` — runs the Docker CLI (`system df --format json`, then `prune` per category) and parses the result. It works with Docker Desktop and OrbStack.
- `ContentView.swift`, `App.swift` — a window and a menu bar item sharing the same models.

## Incremental rescans

The app remembers the last result (`~/Library/Application Support/DevCacheClean/size-cache.json`) together with the macOS file system event id and the volume's event-history UUID. On the next scan it asks the system which folders changed since then (FSEvents, replayed from the log) and only re-measures those:

- a change inside a known cache re-sizes that cache;
- a change in any other folder rescans that folder (to `max_depth`, keeping its depth below the root);
- a change in the root itself, too many changed folders, dropped events, a different volume history, a result older than 24 h, or any error falls back to a full scan.

The "Rescan" button is incremental; its context menu has "Full rescan". The window shows which kind of scan ran. `./test-incremental.sh` checks that an incremental rescan equals a full scan after real changes (growing, creating, deleting caches).

## Git check

`GitCheck.swift` runs `git` read-only for the project that owns each cache (its parent folder): is it a work tree, does git track files inside the cache folder (`ls-files`, literal pathspec), is the folder dirty (`status --porcelain`, untracked files included), how many commits are not on the upstream (`rev-list --count @{u}..HEAD`, or `-1` when there is no upstream but there are commits). Every call passes `-c core.fsmonitor=false -c core.hooksPath=/dev/null`, runs with `GIT_OPTIONAL_LOCKS=0`, drops `GIT_DIR`-style variables and has a 20 s timeout; the system `/usr/bin/git` shim is only used when developer tools exist. `./test-git.sh` checks it against real repositories, including one whose config tries to run a program on `git status`.

## Safety rules

1. Only items returned by a scan can be acted on.
2. Dev caches go to the Trash (reversible). Docker prunes are permanent and always ask first, showing what is lost.
3. The app makes no network requests.
4. Credentials, tool settings and source code are never part of the catalog.

## Measured performance

On the author's `~/development` (about 550 caches, 34 GB, Apple silicon): 4 min 23 s (single thread, one `stat` per file) → 1 min 30 s (parallel sizing) → about 20 s (parallel discovery and sizing with `getattrlistbulk`). Results were checked against `find` and `du`. With nothing changed, an incremental rescan took 0.0 s for `~/development` (3.6 s full) and 0.1 s for the global catalog (60 s full).
