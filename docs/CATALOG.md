# Catalog

Everything Dev Cache Clean can list, taken from [`src/catalog.zig`](../src/catalog.zig) (global tool data) and [`src/targets.zig`](../src/targets.zig) (per-project caches). If this page and the source disagree, the source is right.

## Global tool data (System tab)

The 40 locations below are checked under your home directory. A location appears in the app only if it exists and is not empty. Paths are relative to `~`. Items are listed largest first.

**Categories:** `cache` (rebuilt automatically), `build_output` (compiler or IDE output, rebuilt by the next build), `logs`, `tracking` (telemetry, analytics or usage statistics kept on disk), `history` (conversations, sessions or other work you may want to keep).

**Risk:** `safe` (regenerated on demand; costs only time or bandwidth) or `careful` (removing it loses something you may want; never pre-selected).

| Tool | Name | Path (relative to `~`) | Category | Risk | If removed |
| --- | --- | --- | --- | --- | --- |
| Claude Code | Conversations | `.claude/projects` | history | careful | Past conversations and any saved memory notes for each project; they can no longer be resumed. |
| Claude Code | File checkpoints | `.claude/file-history` | history | careful | The ability to rewind edits from past sessions. |
| Claude Code | Shell snapshots | `.claude/shell-snapshots` | cache | safe | Nothing; recreated for each session. |
| Claude Code | Telemetry queue | `.claude/telemetry` | tracking | safe | Usage events that were not sent yet. |
| Claude Code | Analytics cache | `.claude/statsig` | tracking | safe | Nothing; fetched again. |
| Claude Code | Debug logs | `.claude/debug` | logs | safe | Logs useful only for bug reports. |
| Claude Code | CLI cache | `Library/Caches/claude-cli-nodejs` | cache | safe | Nothing; recreated. |
| Codex CLI | Sessions | `.codex/sessions` | history | careful | Past Codex conversations. |
| Codex CLI | Logs | `.codex/log` | logs | safe | Logs useful only for bug reports. |
| opencode | Sessions and messages | `.local/share/opencode/storage` | history | careful | Past opencode conversations. |
| opencode | Logs | `.local/share/opencode/log` | logs | safe | Logs useful only for bug reports. |
| opencode | Cache | `.cache/opencode` | cache | careful | opencode downloads them again, but a plugin version that is no longer available will fail to reinstall. |
| VS Code | Cached data | `Library/Application Support/Code/CachedData` | cache | safe | Slightly slower first start. |
| VS Code | Web cache | `Library/Application Support/Code/Cache` | cache | safe | Nothing; recreated. |
| VS Code | Logs | `Library/Application Support/Code/logs` | logs | safe | Old logs. |
| Cursor | Cached data | `Library/Application Support/Cursor/CachedData` | cache | safe | Slightly slower first start. |
| Cursor | Web cache | `Library/Application Support/Cursor/Cache` | cache | safe | Nothing; recreated. |
| Cursor | Logs | `Library/Application Support/Cursor/logs` | logs | safe | Old logs. |
| npm | Package cache | `.npm/_cacache` | cache | safe | Re-download on the next install. |
| npm | Logs | `.npm/_logs` | logs | safe | Old logs. |
| Yarn | Package cache | `Library/Caches/Yarn` | cache | safe | Re-download on the next install. |
| pnpm | Content store | `Library/pnpm/store` | cache | safe | Re-download; projects keep working until reinstalled. |
| Bun | Install cache | `.bun/install/cache` | cache | safe | Re-download on the next install. |
| Cargo | Crate archives | `.cargo/registry/cache` | cache | safe | Re-download on the next build. |
| Cargo | Crate sources | `.cargo/registry/src` | cache | safe | Unpacked again on the next build. |
| Cargo | Git dependencies | `.cargo/git/db` | cache | safe | Cloned again on the next build. |
| Gradle | Dependency cache | `.gradle/caches` | cache | safe | Re-download and a slow first build. |
| Maven | Local repository | `.m2/repository` | cache | careful | Locally installed artifacts that exist nowhere else. |
| Homebrew | Downloads | `Library/Caches/Homebrew` | cache | safe | Re-download when reinstalling. |
| pip | Wheel cache | `Library/Caches/pip` | cache | safe | Re-download on the next install. |
| uv | Package cache | `.cache/uv` | cache | safe | Re-download on the next install. |
| Go | Build cache | `Library/Caches/go-build` | build_output | safe | A slower next build. |
| Go | Module cache | `go/pkg/mod/cache` | cache | safe | Re-download on the next build. |
| CocoaPods | Pod cache | `Library/Caches/CocoaPods` | cache | safe | Re-download on the next pod install. |
| Playwright | Browsers | `Library/Caches/ms-playwright` | cache | safe | Re-download with `npx playwright install`. |
| Puppeteer | Browsers | `.cache/puppeteer` | cache | safe | Re-download on the next run. |
| Xcode | DerivedData | `Library/Developer/Xcode/DerivedData` | build_output | safe | A full rebuild and re-index. |
| Xcode | iOS DeviceSupport | `Library/Developer/Xcode/iOS DeviceSupport` | cache | safe | Copied again when the device is connected. |
| Xcode | Archives | `Library/Developer/Xcode/Archives` | history | careful | Builds you may need to symbolicate crashes or re-submit. |
| Simulator | Simulator caches | `Library/Developer/CoreSimulator/Caches` | cache | safe | Nothing; recreated. |

Six entries are `careful`: the five `history` entries (Claude Code conversations and file checkpoints, Codex sessions, opencode sessions, Xcode archives) and Maven's local repository, which can hold artifacts you installed locally.

## Per-project caches (Dev caches tab)

Found by walking a folder you choose (default `~/development`, or your home folder if that does not exist). A directory only counts when its marker file sits next to it. The walk goes at most 8 levels deep, never follows symbolic links and never enters `.git`, `Library`, `.Trash`, `.cache` or `Applications`.

| Directory | Marker file next to it | Label |
| --- | --- | --- |
| `node_modules` | `package.json` | node |
| `.next` | `package.json` | next |
| `target` | `Cargo.toml` | rust |
| `.zig-cache` | `build.zig` | zig |
| `.venv` | none | python |
| `__pycache__` | none | python |
| `Pods` | `Podfile` | cocoapods |

Each result shows how many days the owning project has been idle (the age of the newest file in that project).

## Docker (Docker tab)

Not part of the catalog. The app runs `docker system df --format json` and offers one cleanup per category: unused images (`image prune -a -f`), stopped containers (`container prune -f`), unused volumes (`volume prune -f`) and build cache (`builder prune -a -f`). These are permanent and always ask first.

## Rules

- Credentials, tool settings and source code are never listed.
- `history` entries are always `careful` and are never pre-selected. The System tab's "Select safe" button skips every `careful` item and every `history` item.
- Only items returned by a scan can be acted on, and symbolic links are refused.
- Removal goes to the Trash by default. "Delete now" is permanent and always asks for confirmation.

## Sizes can overstate what you free

Sizes are allocated bytes on disk. pnpm's store and Bun's install cache are hard-linked or cloned into your projects' `node_modules`, so deleting the store may free less space than shown, because projects still reference the same data. Projects keep working until you reinstall.

## Adding an entry

See [CONTRIBUTING.md](../CONTRIBUTING.md). Say how you verified the path and what the user loses.
