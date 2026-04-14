# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Redeye is a macOS menu bar app that keeps Claude Code sessions alive in the background using `tmux`. It manages multiple project directories, each with its own detached tmux session running `claude` under `caffeinate -is`.

## Repo Structure

- `Redeye.app.zip` — Pre-built app bundle, unzip and copy to `/Applications`
- `app/` — Source files (Redeye.swift, Info.plist, shell script, icon, etc.)
- `mcp/` — MCP server (`redeye_server.py`) for cross-session control from Claude Code

## Build

```bash
mkdir -p Redeye.app/Contents/{MacOS,Resources}
swiftc -o Redeye.app/Contents/MacOS/Redeye app/Redeye.swift -framework AppKit
cp app/Info.plist Redeye.app/Contents/
cp app/Redeye.icns app/instructions.txt app/claude-ordo-keepalive.sh mcp/redeye_server.py Redeye.app/Contents/Resources/
codesign --force --deep -s - Redeye.app
```

To install, copy the built `Redeye.app` to `/Applications`. The ad-hoc signature avoids the "damaged" Gatekeeper error — users get the standard "unidentified developer" prompt instead.

There is no Xcode project, Package.swift, or test suite. The app is a single-file Swift program compiled directly with `swiftc`.

## Deploy & Release

After any code change, run the full deploy-and-release flow. This builds, signs, zips, commits, pushes, and creates a GitHub Release so the auto-updater picks it up:

```bash
# 1. Bump version in Info.plist (e.g. 1.0.0 -> 1.1.0)
# Edit app/Info.plist CFBundleShortVersionString

# 2. Build, sign, and zip for distribution
mkdir -p Redeye.app/Contents/{MacOS,Resources}
swiftc -o Redeye.app/Contents/MacOS/Redeye app/Redeye.swift -framework AppKit
cp app/Info.plist Redeye.app/Contents/
cp app/Redeye.icns app/instructions.txt app/claude-ordo-keepalive.sh mcp/redeye_server.py Redeye.app/Contents/Resources/
codesign --force --deep -s - Redeye.app
rm -f Redeye.app.zip
zip -r Redeye.app.zip Redeye.app/
rm -rf Redeye.app

# 3. Update local install
swiftc -o /Applications/Redeye.app/Contents/MacOS/Redeye app/Redeye.swift -framework AppKit
cp app/Info.plist /Applications/Redeye.app/Contents/
cp app/claude-ordo-keepalive.sh mcp/redeye_server.py /Applications/Redeye.app/Contents/Resources/
codesign --force --deep -s - /Applications/Redeye.app

# 4. Commit, push, and create release
git add app/ Redeye.app.zip
git commit -m "vX.Y.Z — description"
git push
gh release create vX.Y.Z Redeye.app.zip --title "vX.Y.Z" --notes "description"
```

The app checks `https://api.github.com/repos/hrosenblume/redeye/releases/latest` on launch (once per day) and prompts users to download if a newer version exists. Always bump the version, create a release, and attach the zip — all three are required for the auto-updater to work.

## Architecture

**app/Redeye.swift** — The entire macOS app in one file. Key components:
- `Project` — Codable model storing path + enabled state; persisted via `UserDefaults`
- `SessionState` — enum: `.stopped`, `.running`, `.attached`
- `StatusBarController` — owns the `NSStatusItem`, menu construction, polling timer (30s), and all user actions (start/stop/attach/add/remove projects). Shells out to the keepalive script via `Process`.
- Entry point at bottom of file — sets activation policy to `.accessory` (no dock icon), creates `AppDelegate`, runs `NSApplication`.

**app/claude-ordo-keepalive.sh** — Shell script invoked by the Swift app with `{start|stop|status} <session_name> [project_dir]`. Manages tmux sessions. `start` runs `caffeinate -is claude` inside a detached tmux session. `status` checks `tmux has-session` and validates attached client PIDs to distinguish running vs. attached vs. stopped.

**mcp/redeye_server.py** — FastMCP server (stdio transport) giving any Claude Code session tools to manage Redeye sessions (`redeye_list_projects`, `redeye_start_session`, `redeye_stop_session`, `redeye_list_sessions`, `redeye_capture_output`, `redeye_send_keys`). Bundled into the app at `Contents/Resources/redeye_server.py`. Replicates the Swift FNV-1a hash for session naming. Reads project list from UserDefaults via `defaults export`. Auto-configured into `~/.claude/.mcp.json` on app launch.

**app/Info.plist** — Bundle metadata. `LSUIElement = true` prevents dock icon flash on launch.

## Key Details

- The script, instructions.txt, redeye_server.py, and Info.plist are bundled inside the `.app` bundle.
- The shell script resolves `claude` and `tmux` dynamically via `command -v` with common paths added to `$PATH`.
- Session names are derived from the project folder name + a hash of the full path (e.g., `redeye-myproject-a1b2c3`).
- The app uses `NSOpenPanel` for folder selection and AppleScript (`osascript`) to open Terminal for session attachment.
- Auto-start on login is handled by a LaunchAgent plist (`~/Library/LaunchAgents/com.hrosenblume.claude-ordo.plist`).

## Code Style

Write Swift like a senior engineer: DRY, concise, idiomatic.

- **No duplication.** Extract repeated logic into functions, computed properties, or extensions. If you write the same pattern twice, refactor.
- **Prefer Swift idioms.** Use `guard`, `map`/`filter`/`compactMap`, trailing closures, extensions, and enums with associated values over verbose if/else chains or stringly-typed code.
- **Minimal surface area.** Keep types, methods, and properties `private` by default. Only expose what's needed.
- **No boilerplate.** Don't add redundant type annotations, unnecessary `self.`, or obvious comments. Let the code speak.
- **Single responsibility.** Each type/method does one thing. If a method is doing two things, split it.
- **Constants over magic values.** Use the `Config` enum or similar for any literal that appears more than once.
