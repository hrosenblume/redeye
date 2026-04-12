# Redeye

Keeps your Claude awake.

A macOS menu bar app that keeps Claude Code sessions alive in the background using `tmux`.

## What it does

- Manages multiple project directories, each with its own detached tmux session running `claude` under `caffeinate -is`
- Shows a coffee cup icon in your menu bar — filled when running, outlined when stopped
- Start/stop sessions, attach via Terminal, add/remove projects from the menu
- Auto-starts on login via LaunchAgent

## Install

1. Download `Redeye.app.zip` from this repo
2. Unzip and move `Redeye.app` to `/Applications`
3. Remove the quarantine flag (required for unsigned apps):
   ```bash
   xattr -cr /Applications/Redeye.app
   ```
4. Requires `tmux` (`brew install tmux`) and [Claude Code](https://claude.ai/code)

## Build from source

```bash
mkdir -p Redeye.app/Contents/{MacOS,Resources}
swiftc -o Redeye.app/Contents/MacOS/Redeye app/Redeye.swift -framework AppKit
cp app/Info.plist Redeye.app/Contents/
cp app/Redeye.icns app/instructions.txt app/claude-ordo-keepalive.sh Redeye.app/Contents/Resources/
```

## Auto-start on login

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
        <string>/Applications/Redeye.app</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```
