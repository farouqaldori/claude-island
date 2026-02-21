# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Claude Island is a macOS menu bar app that displays Claude Code CLI sessions in a Dynamic Island-style notch interface. It communicates with Claude Code via a Python hook script (`claude-island-state.py`) over a Unix socket (`/tmp/claude-island.sock`), enabling live session monitoring and tool permission approvals directly from the MacBook notch.

Fork of [farouqaldori/claude-island](https://github.com/farouqaldori/claude-island) with strict linting, modern Swift concurrency, and bug fixes.

## Build & Lint

```bash
# Build (xcodebuild)
xcodebuild -scheme ClaudeIsland -configuration Release build

# Build release DMG (ad-hoc signed)
./scripts/build.sh

# Lint (run both in order)
swiftformat .
swiftlint lint --strict

# Run all pre-commit checks
prek run --all-files
```

**No test targets exist.** The project has no unit or integration tests.

## Requirements

- macOS 15.6+, Xcode 16.x, Swift 6 (language mode 6.2)
- CLI tools: `swiftformat`, `swiftlint`, `shellcheck`, `prek` (pre-commit runner)
- Python 3.14+ (for the hook script only)

## Swift Concurrency Settings

The project uses Swift 6.2 with aggressive concurrency enforcement:

| Build Setting | Value |
|---|---|
| `SWIFT_STRICT_CONCURRENCY` | `complete` |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | `MainActor` |
| `SWIFT_APPROACHABLE_CONCURRENCY` | `YES` |

**Key implication:** Everything defaults to `@MainActor`. Types that must be `nonisolated` require ALL their extensions to also be `nonisolated` — otherwise extensions inherit MainActor and synthesized conformances (Equatable, Hashable, Codable) cross isolation boundaries.

## Architecture

### Event Flow (the critical path)

```
Claude Code CLI
  → Python hook script (~/.claude/hooks/claude-island-state.py)
    → Unix socket (/tmp/claude-island.sock)
      → HookSocketServer (actor, parses JSON events)
        → SessionStore.process(event:) (actor, single mutation entry point)
          → AsyncStream broadcast to subscribers
            → ClaudeSessionMonitor (@Observable, MainActor UI bridge)
              → SwiftUI notch views
```

Permission approvals flow back: SwiftUI → ToolApprovalHandler → TmuxController → terminal.

### State Management: SessionStore (the only source of truth)

`SessionStore` is an **actor** and the sole place session state mutates. All state changes enter through `process(_ event: SessionEvent)`, which:

- Validates transitions via `SessionPhase.canTransition(to:)`
- Broadcasts changes to subscribers via UUID-keyed `AsyncStream` continuations
- Records an audit trail

**SessionPhase** is a strict state machine: `idle → processing → waitingForInput / waitingForApproval / compacting → ended`.

### Key Model Types (all `nonisolated`, `Sendable`)

- **`SessionState`** — Complete state for one Claude session (phase, chat items, tool tracker, subagent state)
- **`SessionPhase`** — State machine enum with associated values (e.g. `.waitingForApproval(PermissionContext)`)
- **`JSONValue`** — Recursive enum replacing `AnyCodable` for type-safe, inherently `Sendable` JSON
- **`ChatHistoryItem`** — Enum: `.text`, `.toolUse`, `.thinking`, `.toolResult`, `.interrupted`

### Service Domains

| Domain | Key Type | Purpose |
|---|---|---|
| Hooks | `HookSocketServer` (actor, 919 lines) | Unix socket server, bidirectional hook events, permission req/resp |
| Session | `ConversationParser` (actor) | Parses JSONL chat files with incremental sync |
| Session | `ClaudeSessionMonitor` (@Observable) | MainActor bridge from SessionStore to SwiftUI |
| Session | `AgentFileWatcher` | Monitors subagent directory for Task tool state |
| State | `SessionStore` (actor) | Central state management, event processing |
| State | `ToolEventProcessor` | Tool-specific state transitions |
| Tmux | `TmuxController` / `ToolApprovalHandler` | Sends approval/denial decisions to terminal |
| TokenTracking | `ClaudeAPIService` | Fetches token usage quota |
| Update | `NotchUserDriver` | Custom Sparkle UI for in-notch update notifications |
| Window | `NotchWindowController` | Notch window lifecycle and geometry |

### AsyncStream Patterns

Three patterns are used consistently:

1. **Multi-subscriber broadcast** (SessionStore): UUID-keyed continuation dictionary, yield current state on registration, deregister via `onTermination`
2. **Single-consumer stream** (EventMonitors, NotchViewModel): Single optional continuation, factory method creates stream with `.bufferingNewest(1)`
3. **Void streams**: `AsyncStream<Void>` needs `_ = continuation?.yield(())` to disambiguate return type

### SPM Dependencies

| Package | Purpose |
|---|---|
| `swift-markdown` (Apple) | Markdown parsing for chat rendering |
| `Sparkle` | macOS auto-update framework |
| `OcclusionKit` | MacBook notch detection |
| `swift-subprocess` | Safe process execution wrapper |

## Linting Gotchas

- **SwiftFormat `organizeDeclarations`** strips explicit `nonisolated static func ==` bodies when it thinks they're synthesizable. This breaks types that need `nonisolated` Equatable for cross-actor use. Wrap with `// swiftformat:disable all` / `// swiftformat:enable all`. Currently affects `PermissionContext` in `SessionPhase.swift`.
- **SwiftLint `no_print_statements`** is a custom rule — use `os.Logger` instead of `print()`.
- **`HookSocketServer.swift`** is excluded from several lint rules (919 lines, high cyclomatic complexity).
- Max line width: 150 characters. 4-space indentation.

## Python Hook Script

`ClaudeIsland/Resources/claude-island-state.py` (~500 lines, Python 3.14+) is installed into `~/.claude/hooks/` on first launch. It sends hook events over the Unix socket and waits for permission decisions (5-minute timeout). Linted with `ruff`.

## Release Process

1. Manual trigger of `.github/workflows/release.yml`
2. Builds DMG via `scripts/build.sh` + `scripts/create-release.sh`
3. Creates GitHub release, scans with VirusTotal API
4. Appends scan results to release notes
5. Triggers website auto-update (`claude-island-web` repo)
6. Sparkle appcast at `https://claudeisland.engels74.net/appcast.xml`
