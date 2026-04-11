#!/bin/bash
# Claude Code keepalive manager for ordo-internal.
# Uses a detached screen session -- no Terminal.app window.

PROJECT_DIR="/Users/hrosenblume/Local/Code/ordo-internal"
SESSION_NAME="claude-ordo"
CLAUDE_BIN="/Users/hrosenblume/.local/bin/claude"

case "${1:-status}" in
  start)
    if screen -ls 2>/dev/null | grep -q "\.${SESSION_NAME}[[:space:]]"; then
      echo "already running"
      exit 0
    fi
    screen -dmS "$SESSION_NAME" bash -c "cd '$PROJECT_DIR' && caffeinate -is '$CLAUDE_BIN'"
    echo "started"
    ;;
  stop)
    screen -S "$SESSION_NAME" -X quit 2>/dev/null
    echo "stopped"
    ;;
  status)
    if screen -ls 2>/dev/null | grep -q "\.${SESSION_NAME}[[:space:]]"; then
      echo "running"
    else
      echo "stopped"
    fi
    ;;
  *)
    echo "Usage: $0 {start|stop|status}"
    exit 1
    ;;
esac
