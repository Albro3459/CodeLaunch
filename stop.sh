#!/usr/bin/env bash
# Tears the remote-agent stack down in reverse order and guards each kill so a re-run is a clean no-op.
# Leaves Docker Desktop, the daemon, and native Claude Code sessions running - see SETUP.md "Step 5" for details.
set -euo pipefail
cd "$(dirname "$0")"

# --- a. env (defaults if .env is gone) ---
if [ -f .env ]; then set -a; . ./.env; set +a; fi
: "${T3_PORT:=3773}"
: "${TUNNEL_NAME:=t3-code}"

# --- b. tunnel (SIGTERM, honor 30s grace, force with a second signal) ---
if pgrep -f "cloudflared tunnel run" >/dev/null; then
  echo "stopping tunnel ..."
  pkill -f "cloudflared tunnel run" || true
  for _ in $(seq 1 35); do
    pgrep -f "cloudflared tunnel run" >/dev/null || break
    sleep 1
  done
  if pgrep -f "cloudflared tunnel run" >/dev/null; then
    echo "tunnel still up after grace - sending second signal"
    pkill -f "cloudflared tunnel run" || true
  fi
  echo "tunnel stopped"
else
  echo "tunnel already stopped"
fi

# --- c. T3 backend on $T3_PORT ---
# The desktop app gets a graceful AppleScript quit, while a headless `t3 serve` just gets killed.
# The bundle name comes from the process path, not T3_CHANNEL, so a stale setting can't break the quit.
t3_pid=$(lsof -nP -iTCP:"$T3_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)
t3_cmd=$(ps -p "${t3_pid:-0}" -o command= 2>/dev/null || true)
# Strips at the first ".app/" to get the outermost bundle.
# Nested Electron helper bundles won't respond to `quit app`, only the outer one will.
app_name=""
case "$t3_cmd" in
  *.app/Contents/*) app_name=$(basename "${t3_cmd%%.app/*}") ;;
esac
if [ -z "$t3_pid" ]; then
  echo "no T3 backend listening on :$T3_PORT"
elif [ -n "$app_name" ]; then
  echo "quitting T3 Desktop app \"$app_name\" (PID $t3_pid) ..."
  osascript -e "quit app \"$app_name\"" || true
  for _ in $(seq 1 15); do
    kill -0 "$t3_pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$t3_pid" 2>/dev/null; then
    echo "WARNING: \"$app_name\" still running after 15s - it may be showing a dialog. Quit it manually."
  else
    echo "T3 Desktop quit"
  fi
else
  echo "stopping headless T3 backend (PID $t3_pid) ..."
  kill "$t3_pid" 2>/dev/null || true
  for _ in $(seq 1 15); do
    kill -0 "$t3_pid" 2>/dev/null || break
    sleep 1
  done
  kill -9 "$t3_pid" 2>/dev/null || true
  echo "headless T3 backend stopped"
fi

# --- d. claudex Claude sessions only ---
# Matches the CLAUDE_CONFIG_DIR marker in the process environment so native Claude Code sessions are left alone.
marker="CLAUDE_CONFIG_DIR=$HOME/.claudex"
claudex_pids=$(ps eww -ax -o pid=,command= 2>/dev/null \
  | grep -F "$marker" | grep -E '/claude( |$)' | awk '{print $1}' || true)
if [ -n "$claudex_pids" ]; then
  echo "stopping claudex sessions: $(echo "$claudex_pids" | tr '\n' ' ')"
  for p in $claudex_pids; do kill "$p" 2>/dev/null || true; done
else
  echo "no claudex sessions running"
fi

# --- e. proxy (only if docker reachable) ---
if docker info >/dev/null 2>&1; then
  echo "stopping proxy ..."
  ./cliproxy/stop.sh || true
else
  echo "docker not reachable - skipping proxy stop"
fi

# --- f. caffeinate ---
if pgrep -f 'caffeinate -dims' >/dev/null; then
  pkill -f 'caffeinate -dims' || true
  echo "stopped caffeinate (display/idle assertions released)"
else
  echo "no caffeinate to stop"
fi

# --- g. left running on purpose ---
echo "left running: Docker Desktop + daemon, native Claude Code sessions"
