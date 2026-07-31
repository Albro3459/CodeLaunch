#!/usr/bin/env bash
# Tears the remote-agent stack down in reverse order and guards each kill so a re-run is a clean no-op.
# Leaves Docker Desktop, the daemon, native Claude Code sessions, and caffeinate running - see SETUP.md "Step 5" for details.
set -euo pipefail
umask 077
cd "$(dirname "$0")"
. ./scripts/env.sh

usage() {
  cat <<'EOF'
Usage: ./stop.sh [-a|--all]
       ./stop.sh -h|--help
EOF
}

ALL=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -a|--all)
      [ "$ALL" = 0 ] || { echo "duplicate --all option" >&2; usage >&2; exit 2; }
      ALL=1; shift
      ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) echo "unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- a. env (defaults if .env is gone) ---
codelaunch_private_file .env
codelaunch_load_env --optional T3_PORT TUNNEL_NAME
: "${T3_PORT:=3773}"
: "${TUNNEL_NAME:=t3-code}"

# --- b. tunnel (SIGTERM, honor 30s grace, force with a second signal) ---
tunnel_pids=$(codelaunch_tunnel_pids "$TUNNEL_NAME")
if [ -n "$tunnel_pids" ]; then
  echo "stopping tunnel $TUNNEL_NAME ..."
  for p in $tunnel_pids; do kill "$p" 2>/dev/null || true; done
  for _ in $(seq 1 35); do
    tunnel_alive=0
    for p in $tunnel_pids; do
      if kill -0 "$p" 2>/dev/null; then tunnel_alive=1; break; fi
    done
    [ "$tunnel_alive" = 0 ] && break
    sleep 1
  done
  tunnel_pids=$(codelaunch_tunnel_pids "$TUNNEL_NAME")
  if [ -n "$tunnel_pids" ]; then
    echo "tunnel still up after grace - sending second signal"
    for p in $tunnel_pids; do kill "$p" 2>/dev/null || true; done
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
  osascript - "$app_name" <<'APPLESCRIPT' || true
on run argv
  set targetApp to item 1 of argv
  tell application targetApp to quit
end run
APPLESCRIPT
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

if [ "$ALL" = 1 ]; then
  # --- f. Docker Desktop (guarded, nonfatal) ---
  if command -v docker >/dev/null 2>&1 && docker desktop --help >/dev/null 2>&1; then
    echo "stopping Docker Desktop ..."
    docker desktop stop || echo "WARNING: Docker Desktop stop failed; leaving it running"
  else
    echo "WARNING: Docker Desktop CLI unavailable; leaving it running"
  fi

  # --- g. CodeLaunch-owned caffeinate only ---
  caffeinate_pid=''
  if caffeinate_pid=$(codelaunch_caffeinate_owned_pid); then
    if codelaunch_caffeinate_record_pid &&
      [ "$CODELAUNCH_CAFFEINATE_PID" = "$caffeinate_pid" ] &&
      kill -0 "$caffeinate_pid" 2>/dev/null &&
      codelaunch_caffeinate_exact_command "$caffeinate_pid" &&
      [ "$(codelaunch_caffeinate_start_identity "$caffeinate_pid")" = "$CODELAUNCH_CAFFEINATE_START_IDENTITY" ]; then
      kill "$caffeinate_pid" 2>/dev/null || true
      for _ in $(seq 1 10); do
        kill -0 "$caffeinate_pid" 2>/dev/null || break
        sleep 1
      done
      if kill -0 "$caffeinate_pid" 2>/dev/null &&
        codelaunch_caffeinate_record_pid &&
        [ "$CODELAUNCH_CAFFEINATE_PID" = "$caffeinate_pid" ] &&
        codelaunch_caffeinate_exact_command "$caffeinate_pid" &&
        [ "$(codelaunch_caffeinate_start_identity "$caffeinate_pid")" = "$CODELAUNCH_CAFFEINATE_START_IDENTITY" ]; then
        kill -9 "$caffeinate_pid" 2>/dev/null || true
      fi
      if ! kill -0 "$caffeinate_pid" 2>/dev/null; then
        codelaunch_caffeinate_clear_record
        echo "CodeLaunch-owned caffeinate stopped"
      else
        echo "WARNING: CodeLaunch-owned caffeinate is still running"
      fi
    else
      echo "WARNING: caffeinate ownership changed; refusing to signal PID $caffeinate_pid"
    fi
  else
    caffeinate_status=$?
    if [ "$caffeinate_status" -eq 1 ]; then
      echo "no CodeLaunch-owned caffeinate running"
    else
      echo "WARNING: invalid caffeinate ownership record; leaving caffeinate running"
    fi
  fi
  echo "native Claude Code sessions and T3 Connect relays remain running"
else
  # --- f. left running on purpose ---
  echo "left running: Docker Desktop + daemon, native Claude Code sessions, caffeinate, T3 Connect relays"
  echo "Use ./stop.sh --all to also stop Docker Desktop and CodeLaunch-owned caffeinate."
fi
