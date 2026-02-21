<div align="center">
  <img src="docs/logo.svg" alt="Logo" width="256" height="256">
  <p>
    <a href="https://github.com/engels74/claude-island/releases/latest" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/github/v/release/engels74/claude-island?style=rounded&color=white&labelColor=000000&label=release" alt="Release Version" />
    </a>
    <a href="#" target="_blank" rel="noopener noreferrer">
      <img alt="GitHub Downloads" src="https://img.shields.io/github/downloads/engels74/claude-island/total?style=rounded&color=white&labelColor=000000">
    </a>
    <a href="https://opensource.org/licenses/Apache-2.0" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/badge/License-Apache%202.0-blue.svg?style=rounded&labelColor=000000" alt="License: Apache 2.0">
    </a>
    <a href="#" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/badge/Swift-6-F05138.svg?style=rounded&labelColor=000000" alt="Swift 6">
    </a>
    <a href="https://deepwiki.com/engels74/claude-island">
      <img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki">
    </a>
  </p>
  <h3 align="center">Claude Island</h3>
  <p align="center">
    A macOS menu bar app that brings Dynamic Island-style notifications to Claude Code CLI sessions.
  </p>
</div>

## Features

- **Notch UI** — Animated overlay that expands from the MacBook notch
- **Live Session Monitoring** — Track multiple Claude Code sessions in real-time
- **Permission Approvals** — Approve or deny tool executions directly from the notch
- **Chat History** — View full conversation history with markdown rendering
- **Auto-Setup** — Hooks install automatically on first launch

## About This Fork

This is a fork of the original [claude-island](https://github.com/farouqaldori/claude-island) by farouqaldori.

Key improvements in this fork:

- **Code quality** — Strict linting with SwiftFormat, SwiftLint (70+ rules), pre-commit hooks, and modern Swift concurrency (`@Observable`, `Sendable`, structured concurrency)
- **Bug fixes** — Various stability and reliability improvements
- **Merged upstream PRs** — See [merged pull requests](https://github.com/engels74/claude-island/pulls?q=is%3Apr+is%3Amerged+) for integration details

## Requirements

- macOS 15.6+
- Claude Code CLI

## Installation Guide

### Step 1 — Install the App

Download the latest `.dmg` from [GitHub Releases](https://github.com/engels74/claude-island/releases/latest), open it, and drag **Claude Island** into **Applications**. [`IMG`](docs/screenshots/cropped/001.png)

### Step 2 — Bypass Gatekeeper

Claude Island is ad-hoc signed and not notarized, so macOS blocks the first launch.

1. Open the app — macOS shows **"Claude Island" Not Opened**. Click **Done**. [`IMG`](docs/screenshots/cropped/002.png)
2. Go to **System Settings → Privacy & Security**, find the blocked notice, and click **Open Anyway**. [`IMG`](docs/screenshots/cropped/003.png)
3. In the confirmation dialog, click **Open Anyway**. [`IMG`](docs/screenshots/cropped/004.png)
4. Authenticate with Touch ID or your password. [`IMG`](docs/screenshots/cropped/005.png)

### Step 3 — Grant Keychain Access

macOS prompts for access to **"Claude Code-credentials"** (the CLI's OAuth token, used for optional usage-quota tracking). Click **Always Allow**. [`IMG`](docs/screenshots/cropped/006.png)

### Step 4 — Grant Accessibility Permission

1. The app shows an **Accessibility Permission Required** dialog. Click **Open Settings**. [`IMG`](docs/screenshots/cropped/007.png)
2. In **System Settings → Privacy & Security → Accessibility**, click the **+** button. [`IMG`](docs/screenshots/cropped/008.png)
3. Navigate to **Applications**, select **Claude Island**, and click **Open**. [`IMG`](docs/screenshots/cropped/009.png)
4. Claude Island now appears in the Accessibility list with the toggle enabled. [`IMG`](docs/screenshots/cropped/010.png)

> **Tip:** If Claude Island is already listed but not working, remove it first (click **−**), then re-add it with the steps above.

Subsequent launches require no extra setup. Auto-updates via Sparkle work normally.

**Permissions Questions?** Learn more about [why Claude Island needs accessibility and keychain permissions](https://deepwiki.com/search/is-claude-island-safe-to-use-i_b6aed731-54db-4ac4-89e5-7ce9ad984006).

### Alternative: Terminal Bypass

If you prefer, you can skip the Gatekeeper steps above by removing the quarantine attribute:

```bash
xattr -d com.apple.quarantine "/Applications/Claude Island.app"
```

### Alternative: Build from Source

```bash
xcodebuild -scheme ClaudeIsland -configuration Release build
```

### Walkthrough

![Installation guide walkthrough](docs/screenshots/gif/installation-guide.gif)

## How It Works

Claude Island installs hooks into `~/.claude/hooks/` that communicate session state via a Unix socket. The app listens for events and displays them in the notch overlay.

When Claude needs permission to run a tool, the notch expands with approve/deny buttons—no need to switch to the terminal.

## Remote Sessions (SSH)

Claude Island can monitor Claude Code sessions running on remote machines via NATS transport. The hook script auto-detects SSH sessions and falls back to NATS when the local Unix socket is unavailable.

**How it works:**
- The hook publishes events to a local NATS server (forwarded via SSH `RemoteForward`)
- A bridge daemon on your Mac subscribes and forwards events to Claude Island
- Permission approve/deny works bidirectionally via NATS request/reply
- Message relay uses tmux proxy panes for sending keystrokes to remote sessions

**Prerequisites:** NATS server on your Mac, SSH `RemoteForward 4222 localhost:4222`

See [`scripts/remote/README.md`](scripts/remote/README.md) for full setup instructions.

## License

Apache 2.0
