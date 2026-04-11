# Redeye

A macOS menu bar app that keeps a Claude Code session alive in the background. Like Caffeine, but for Claude.

## What it does

- Runs a headless Claude Code session via `screen` (no Terminal popups)
- Shows a coffee cup icon in your menu bar -- filled when running, outlined when stopped
- Click to toggle on/off, attach to the session, or quit
- Auto-starts on login via LaunchAgent

## Building

```bash
mkdir -p ~/Applications/Redeye.app/Contents/{MacOS,Resources}
swiftc -o ~/Applications/Redeye.app/Contents/MacOS/Redeye Redeye.swift -framework AppKit
```

## Setup

1. Copy `claude-ordo-keepalive.sh` to `~/.local/bin/` and `chmod +x` it
2. Build and place `Redeye.app` in `~/Applications/`
3. Add a LaunchAgent to auto-start on login (see below)

```xml
<!-- ~/Library/LaunchAgents/com.hrosenblume.claude-ordo.plist -->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.hrosenblume.claude-ordo</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>/Users/hrosenblume/Applications/Redeye.app</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```
