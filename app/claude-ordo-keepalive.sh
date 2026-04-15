#!/bin/bash
# Redeye: Claude Code keepalive manager.
# Uses detached tmux sessions -- no Terminal.app window.
# Usage: redeye.sh {start|stop|status|list|capture|send|tune} <session_name> [project_dir] [display_name] [permission_mode]

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
    PERMISSION_MODE="${5:-}"
    if [ -n "$PERMISSION_MODE" ] && [ "$PERMISSION_MODE" != "default" ]; then
      CLAUDE_ARGS="$CLAUDE_ARGS --$PERMISSION_MODE"
    fi
    "$TMUX_BIN" new-session -d -s "$SESSION_NAME" -c "$PROJECT_DIR" \
      "export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8; caffeinate -is $CLAUDE_BIN $CLAUDE_ARGS"
    # Mouse off so Terminal.app handles selection / Cmd-click URLs / copy-paste natively.
    # terminal-overrides disables tmux's alternate screen so output flows into
    # Terminal.app's main scrollback (native trackpad scroll shows real history).
    "$TMUX_BIN" set-option -t "$SESSION_NAME" mouse off 2>/dev/null
    "$TMUX_BIN" set-option -t "$SESSION_NAME" history-limit 50000 2>/dev/null
    "$TMUX_BIN" set-option -ga terminal-overrides ',xterm*:smcup@:rmcup@' 2>/dev/null
    echo "started"
    ;;
  start-meta)
    PROJECT_DIR="${3:-$HOME}"
    if [ ! -x "$CLAUDE_BIN" ]; then
      echo "error: claude not found"
      exit 1
    fi
    if "$TMUX_BIN" has-session -t "$SESSION_NAME" 2>/dev/null; then
      echo "already running"
      exit 0
    fi
    SYSTEM_PROMPT="You are Redeye, a persistent session that manages Claude Code sessions running on the user's Mac. You have ONLY Redeye MCP tools -- no file editing, no bash, no coding. When asked what you can do, respond ONLY with your actual capabilities below. Never list generic Claude features.

Your tools: redeye_list_projects (show configured projects), redeye_list_sessions (show running/stopped sessions), redeye_start_session (start a new session for a project), redeye_stop_session (stop a session), redeye_capture_output (read last ~10 lines from a session), redeye_send_keys (type into a session).

Typical usage: list projects to see what is available, start/stop sessions, check on a session's output, or send commands to a running session. Always call your tools to answer questions -- do not guess or assume state. Keep responses short and direct."
    "$TMUX_BIN" new-session -d -s "$SESSION_NAME" -c "$PROJECT_DIR" \
      "export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8; caffeinate -is $CLAUDE_BIN --name redeye --disallowedTools 'Bash,Read,Write,Edit,Glob,Grep,Agent,WebFetch,WebSearch,NotebookEdit,TodoWrite' --mcp-config $HOME/.claude/.mcp.json --remote-control --append-system-prompt \"$SYSTEM_PROMPT\""
    "$TMUX_BIN" set-option -t "$SESSION_NAME" mouse off 2>/dev/null
    "$TMUX_BIN" set-option -t "$SESSION_NAME" history-limit 50000 2>/dev/null
    "$TMUX_BIN" set-option -ga terminal-overrides ',xterm*:smcup@:rmcup@' 2>/dev/null
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
  list)
    "$TMUX_BIN" list-sessions -F '#{session_name}:#{session_attached}' 2>/dev/null \
      | grep "^${SESSION_NAME}"
    ;;
  capture)
    "$TMUX_BIN" capture-pane -t "$SESSION_NAME" -p -S -10 2>/dev/null
    ;;
  send)
    KEYS="${3:-}"
    "$TMUX_BIN" send-keys -t "$SESSION_NAME" "$KEYS" 2>/dev/null
    ;;
  tune)
    "$TMUX_BIN" set-option -t "$SESSION_NAME" mouse off 2>/dev/null
    "$TMUX_BIN" set-option -t "$SESSION_NAME" history-limit 50000 2>/dev/null
    "$TMUX_BIN" set-option -ga terminal-overrides ',xterm*:smcup@:rmcup@' 2>/dev/null
    ;;
  *)
    echo "Usage: $0 {start|stop|status|list|capture|send|tune} <session_name> [args...]"
    exit 1
    ;;
esac
