#!/bin/bash
# Redeye: Claude Code keepalive manager.
# Uses detached tmux sessions -- no Terminal.app window.
# Usage: redeye.sh {start|stop|status} <session_name> [project_dir] [display_name]

# macOS apps launch with a minimal PATH — add common install locations
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.claude/local"

CLAUDE_BIN="$(command -v claude 2>/dev/null || echo "")"
TMUX_BIN="$(command -v tmux 2>/dev/null || echo "")"

ACTION="${1:-}"
SESSION_NAME="${2:-}"

if [ -z "$ACTION" ] || [ -z "$SESSION_NAME" ]; then
  echo "Usage: $0 {start|stop|status} <session_name> [project_dir]"
  exit 1
fi

if [ ! -x "$TMUX_BIN" ]; then
  echo "error: tmux not found at $TMUX_BIN"
  exit 1
fi

case "$ACTION" in
  start)
    PROJECT_DIR="${3:-}"
    DISPLAY_NAME="${4:-}"
    if [ -z "$PROJECT_DIR" ]; then
      echo "error: no project directory specified"
      exit 1
    fi
    if [ ! -d "$PROJECT_DIR" ]; then
      echo "error: directory does not exist: $PROJECT_DIR"
      exit 1
    fi
    if [ ! -x "$CLAUDE_BIN" ]; then
      echo "error: claude not found at $CLAUDE_BIN"
      exit 1
    fi
    if "$TMUX_BIN" has-session -t "$SESSION_NAME" 2>/dev/null; then
      echo "already running"
      exit 0
    fi
    CLAUDE_ARGS=""
    if [ -n "$DISPLAY_NAME" ]; then
      CLAUDE_ARGS="--name \"$DISPLAY_NAME\""
    fi
    "$TMUX_BIN" new-session -d -s "$SESSION_NAME" -c "$PROJECT_DIR" \
      "export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8; caffeinate -is $CLAUDE_BIN $CLAUDE_ARGS"
    echo "started"
    ;;
  stop)
    "$TMUX_BIN" kill-session -t "$SESSION_NAME" 2>/dev/null
    echo "stopped"
    ;;
  status)
    if "$TMUX_BIN" has-session -t "$SESSION_NAME" 2>/dev/null; then
      # Check if any client with a live process is attached to this session
      ATTACHED=false
      while IFS= read -r pid; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
          ATTACHED=true
          break
        fi
      done < <("$TMUX_BIN" list-clients -t "$SESSION_NAME" -F '#{client_pid}' 2>/dev/null)
      if $ATTACHED; then
        echo "attached"
      else
        echo "running"
      fi
    else
      echo "stopped"
    fi
    ;;
  *)
    echo "Usage: $0 {start|stop|status} <session_name> [project_dir]"
    exit 1
    ;;
esac
