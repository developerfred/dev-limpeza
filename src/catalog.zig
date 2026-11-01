//! Known global caches, logs, tracking data and histories of developer tools.
//! Every entry says what it is, what removing it costs and how risky that is,
//! so the user always knows what they are touching. Credentials, tool settings
//! and source code are deliberately absent.
const std = @import("std");

pub const Category = enum {
    /// Rebuilt automatically.
    cache,
    /// Compiler/IDE output, rebuilt by the next build.
    build_output,
    logs,
    /// Telemetry, analytics or usage statistics kept on disk.
    tracking,
    /// Conversations, sessions or other work the user may want to keep.
    history,
};

pub const Risk = enum {
    /// Regenerated on demand; costs only time or bandwidth.
    safe,
    /// Removing it loses something the user may want. Never pre-selected.
    careful,
};

pub const Entry = struct {
    id: []const u8,
    tool: []const u8,
    name: []const u8,
    /// Relative to the home directory.
    path: []const u8,
    description: []const u8,
    loses: []const u8,
    category: Category,
    risk: Risk,
};

pub const entries = [_]Entry{
    // ---- AI coding agents
    .{ .id = "claude-projects", .tool = "Claude Code", .name = "Conversations", .path = ".claude/projects", .category = .history, .risk = .careful, .description = "Transcripts of every Claude Code session, grouped by project.", .loses = "Past conversations; they can no longer be resumed." },
    .{ .id = "claude-file-history", .tool = "Claude Code", .name = "File checkpoints", .path = ".claude/file-history", .category = .history, .risk = .careful, .description = "Copies of files Claude Code saved so edits can be rewound.", .loses = "The ability to rewind edits from past sessions." },
    .{ .id = "claude-shell-snapshots", .tool = "Claude Code", .name = "Shell snapshots", .path = ".claude/shell-snapshots", .category = .cache, .risk = .safe, .description = "Snapshots of your shell environment used to run commands.", .loses = "Nothing; recreated for each session." },
    .{ .id = "claude-telemetry", .tool = "Claude Code", .name = "Telemetry queue", .path = ".claude/telemetry", .category = .tracking, .risk = .safe, .description = "Usage events queued for upload.", .loses = "Usage events that were not sent yet." },
    .{ .id = "claude-statsig", .tool = "Claude Code", .name = "Analytics cache", .path = ".claude/statsig", .category = .tracking, .risk = .safe, .description = "Cached feature flags and analytics state.", .loses = "Nothing; fetched again." },
    .{ .id = "claude-debug", .tool = "Claude Code", .name = "Debug logs", .path = ".claude/debug", .category = .logs, .risk = .safe, .description = "Debug logs from past sessions.", .loses = "Logs useful only for bug reports." },
    .{ .id = "claude-cli-cache", .tool = "Claude Code", .name = "CLI cache", .path = "Library/Caches/claude-cli-nodejs", .category = .cache, .risk = .safe, .description = "Cached CLI and MCP server logs.", .loses = "Nothing; recreated." },
    .{ .id = "codex-sessions", .tool = "Codex CLI", .name = "Sessions", .path = ".codex/sessions", .category = .history, .risk = .careful, .description = "Recorded Codex sessions.", .loses = "Past Codex conversations." },
    .{ .id = "codex-log", .tool = "Codex CLI", .name = "Logs", .path = ".codex/log", .category = .logs, .risk = .safe, .description = "Codex log files.", .loses = "Logs useful only for bug reports." },
    .{ .id = "opencode-storage", .tool = "opencode", .name = "Sessions and messages", .path = ".local/share/opencode/storage", .category = .history, .risk = .careful, .description = "Stored opencode sessions and messages.", .loses = "Past opencode conversations." },
    .{ .id = "opencode-log", .tool = "opencode", .name = "Logs", .path = ".local/share/opencode/log", .category = .logs, .risk = .safe, .description = "opencode log files.", .loses = "Logs useful only for bug reports." },
    .{ .id = "opencode-cache", .tool = "opencode", .name = "Cache", .path = ".cache/opencode", .category = .cache, .risk = .safe, .description = "Downloaded and generated data opencode can fetch again.", .loses = "Nothing; downloaded again." },

    // ---- Editors
    .{ .id = "vscode-cached-data", .tool = "VS Code", .name = "Cached data", .path = "Library/Application Support/Code/CachedData", .category = .cache, .risk = .safe, .description = "Compiled JavaScript cache.", .loses = "Slightly slower first start." },
    .{ .id = "vscode-cache", .tool = "VS Code", .name = "Web cache", .path = "Library/Application Support/Code/Cache", .category = .cache, .risk = .safe, .description = "Chromium cache used by the editor.", .loses = "Nothing; recreated." },
    .{ .id = "vscode-logs", .tool = "VS Code", .name = "Logs", .path = "Library/Application Support/Code/logs", .category = .logs, .risk = .safe, .description = "Editor and extension logs.", .loses = "Old logs." },
    .{ .id = "cursor-cached-data", .tool = "Cursor", .name = "Cached data", .path = "Library/Application Support/Cursor/CachedData", .category = .cache, .risk = .safe, .description = "Compiled JavaScript cache.", .loses = "Slightly slower first start." },
    .{ .id = "cursor-cache", .tool = "Cursor", .name = "Web cache", .path = "Library/Application Support/Cursor/Cache", .category = .cache, .risk = .safe, .description = "Chromium cache used by the editor.", .loses = "Nothing; recreated." },
    .{ .id = "cursor-logs", .tool = "Cursor", .name = "Logs", .path = "Library/Application Support/Cursor/logs", .category = .logs, .risk = .safe, .description = "Editor and extension logs.", .loses = "Old logs." },

    // ---- Package managers and language toolchains
    .{ .id = "npm-cache", .tool = "npm", .name = "Package cache", .path = ".npm/_cacache", .category = .cache, .risk = .safe, .description = "Downloaded package tarballs.", .loses = "Re-download on the next install." },
    .{ .id = "npm-logs", .tool = "npm", .name = "Logs", .path = ".npm/_logs", .category = .logs, .risk = .safe, .description = "npm debug logs.", .loses = "Old logs." },
    .{ .id = "yarn-cache", .tool = "Yarn", .name = "Package cache", .path = "Library/Caches/Yarn", .category = .cache, .risk = .safe, .description = "Downloaded package archives.", .loses = "Re-download on the next install." },
    .{ .id = "pnpm-store", .tool = "pnpm", .name = "Content store", .path = "Library/pnpm/store", .category = .cache, .risk = .safe, .description = "Shared package store linked into node_modules.", .loses = "Re-download; projects keep working until reinstalled." },
    .{ .id = "bun-cache", .tool = "Bun", .name = "Install cache", .path = ".bun/install/cache", .category = .cache, .risk = .safe, .description = "Downloaded packages.", .loses = "Re-download on the next install." },
    .{ .id = "cargo-registry-cache", .tool = "Cargo", .name = "Crate archives", .path = ".cargo/registry/cache", .category = .cache, .risk = .safe, .description = "Downloaded .crate files.", .loses = "Re-download on the next build." },
    .{ .id = "cargo-registry-src", .tool = "Cargo", .name = "Crate sources", .path = ".cargo/registry/src", .category = .cache, .risk = .safe, .description = "Unpacked crate sources.", .loses = "Unpacked again on the next build." },
    .{ .id = "cargo-git", .tool = "Cargo", .name = "Git dependencies", .path = ".cargo/git/db", .category = .cache, .risk = .safe, .description = "Cloned git dependencies.", .loses = "Cloned again on the next build." },
    .{ .id = "gradle-caches", .tool = "Gradle", .name = "Dependency cache", .path = ".gradle/caches", .category = .cache, .risk = .safe, .description = "Downloaded dependencies and build caches.", .loses = "Re-download and a slow first build." },
    .{ .id = "maven-repository", .tool = "Maven", .name = "Local repository", .path = ".m2/repository", .category = .cache, .risk = .careful, .description = "Downloaded artifacts and anything you installed locally.", .loses = "Locally installed artifacts that exist nowhere else." },
    .{ .id = "homebrew-cache", .tool = "Homebrew", .name = "Downloads", .path = "Library/Caches/Homebrew", .category = .cache, .risk = .safe, .description = "Downloaded bottles and sources.", .loses = "Re-download when reinstalling." },
    .{ .id = "pip-cache", .tool = "pip", .name = "Wheel cache", .path = "Library/Caches/pip", .category = .cache, .risk = .safe, .description = "Downloaded wheels and HTTP cache.", .loses = "Re-download on the next install." },
    .{ .id = "uv-cache", .tool = "uv", .name = "Package cache", .path = ".cache/uv", .category = .cache, .risk = .safe, .description = "Downloaded and built Python packages.", .loses = "Re-download on the next install." },
    .{ .id = "go-build", .tool = "Go", .name = "Build cache", .path = "Library/Caches/go-build", .category = .build_output, .risk = .safe, .description = "Compiled package cache.", .loses = "A slower next build." },
    .{ .id = "go-mod", .tool = "Go", .name = "Module cache", .path = "go/pkg/mod/cache", .category = .cache, .risk = .safe, .description = "Downloaded module archives.", .loses = "Re-download on the next build." },
    .{ .id = "cocoapods", .tool = "CocoaPods", .name = "Pod cache", .path = "Library/Caches/CocoaPods", .category = .cache, .risk = .safe, .description = "Downloaded pods.", .loses = "Re-download on the next pod install." },
    .{ .id = "playwright", .tool = "Playwright", .name = "Browsers", .path = "Library/Caches/ms-playwright", .category = .cache, .risk = .safe, .description = "Downloaded test browsers.", .loses = "Re-download with `npx playwright install`." },
    .{ .id = "puppeteer", .tool = "Puppeteer", .name = "Browsers", .path = ".cache/puppeteer", .category = .cache, .risk = .safe, .description = "Downloaded Chrome builds.", .loses = "Re-download on the next run." },

    // ---- Xcode and simulators
    .{ .id = "xcode-derived-data", .tool = "Xcode", .name = "DerivedData", .path = "Library/Developer/Xcode/DerivedData", .category = .build_output, .risk = .safe, .description = "Build products and indexes for every project.", .loses = "A full rebuild and re-index." },
    .{ .id = "xcode-device-support", .tool = "Xcode", .name = "iOS DeviceSupport", .path = "Library/Developer/Xcode/iOS DeviceSupport", .category = .cache, .risk = .safe, .description = "Debug symbols copied from connected devices.", .loses = "Copied again when the device is connected." },
    .{ .id = "xcode-archives", .tool = "Xcode", .name = "Archives", .path = "Library/Developer/Xcode/Archives", .category = .history, .risk = .careful, .description = "App archives from Product > Archive, including dSYMs.", .loses = "Builds you may need to symbolicate crashes or re-submit." },
    .{ .id = "simulator-caches", .tool = "Simulator", .name = "Simulator caches", .path = "Library/Developer/CoreSimulator/Caches", .category = .cache, .risk = .safe, .description = "Cached runtime data.", .loses = "Nothing; recreated." },
};
