# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Redeye is a macOS menu bar app that keeps Claude Code sessions alive in the background using `tmux`. It manages multiple project directories, each with its own detached tmux session running `claude` under `caffeinate -is`.

## Build

```bash
mkdir -p /Applications/Redeye.app/Contents/{MacOS,Resources}
swiftc -o /Applications/Redeye.app/Contents/MacOS/Redeye Redeye.swift -framework AppKit
cp Info.plist /Applications/Redeye.app/Contents/
cp Redeye.icns instructions.txt claude-ordo-keepalive.sh /Applications/Redeye.app/Contents/Resources/
```

There is no Xcode project, Package.swift, or test suite. The app is a single-file Swift program compiled directly with `swiftc`.

## Architecture

**Redeye.swift** — The entire macOS app in one file. Key components:
- `Project` — Codable model storing path + enabled state; persisted via `UserDefaults`
- `SessionState` — enum: `.stopped`, `.running`, `.attached`
- `StatusBarController` — owns the `NSStatusItem`, menu construction, polling timer (30s), and all user actions (start/stop/attach/add/remove projects). Shells out to the keepalive script via `Process`.
- Entry point at bottom of file — sets activation policy to `.accessory` (no dock icon), creates `AppDelegate`, runs `NSApplication`.

**claude-ordo-keepalive.sh** — Shell script invoked by the Swift app with `{start|stop|status} <session_name> [project_dir]`. Manages tmux sessions. `start` runs `caffeinate -is claude` inside a detached tmux session. `status` checks `tmux has-session` and validates attached client PIDs to distinguish running vs. attached vs. stopped.

**Info.plist** — Bundle metadata. `LSUIElement = true` prevents dock icon flash on launch.

## Key Details

- The script, instructions.txt, and Info.plist are bundled inside the `.app` bundle.
- The Claude binary path is hardcoded in the shell script as `/Users/hrosenblume/.local/bin/claude`.
- Session names are derived from the project folder name + a hash of the full path (e.g., `redeye-myproject-a1b2c3`).
- The app uses `NSOpenPanel` for folder selection and AppleScript (`osascript`) to open Terminal for session attachment.
- Auto-start on login is handled by a LaunchAgent plist (`~/Library/LaunchAgents/com.hrosenblume.claude-ordo.plist`) which passes `--background` to suppress opening terminal tabs on login. Normal launch (double-click, Spotlight) opens all session terminals in tabs.

## Code Style

Write Swift like a senior engineer: DRY, concise, idiomatic.

- **No duplication.** Extract repeated logic into functions, computed properties, or extensions. If you write the same pattern twice, refactor.
- **Prefer Swift idioms.** Use `guard`, `map`/`filter`/`compactMap`, trailing closures, extensions, and enums with associated values over verbose if/else chains or stringly-typed code.
- **Minimal surface area.** Keep types, methods, and properties `private` by default. Only expose what's needed.
- **No boilerplate.** Don't add redundant type annotations, unnecessary `self.`, or obvious comments. Let the code speak.
- **Single responsibility.** Each type/method does one thing. If a method is doing two things, split it.
- **Constants over magic values.** Use the `Config` enum or similar for any literal that appears more than once.
