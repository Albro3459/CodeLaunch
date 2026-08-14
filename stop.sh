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
       ./stop.sh t3
       ./stop.sh -h|--help
EOF
}

ALL=0
T3_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -a|--all)
      [ "$ALL" = 0 ] || { echo "duplicate --all option" >&2; usage >&2; exit 2; }
      [ "$T3_ONLY" = 0 ] || { echo "invalid option combination" >&2; usage >&2; exit 2; }
      ALL=1; shift
      ;;
    t3)
      [ "$T3_ONLY" = 0 ] || { echo "duplicate t3 mode" >&2; usage >&2; exit 2; }
      [ "$ALL" = 0 ] || { echo "invalid option combination" >&2; usage >&2; exit 2; }
      T3_ONLY=1; shift
      ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) echo "unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- a. env (defaults if .env is gone) ---
codelaunch_private_file .env
codelaunch_load_env --optional T3_PORT CODEX_WEB_GPT_MANAGED TUNNEL_NAME
: "${T3_PORT:=3773}"
: "${CODEX_WEB_GPT_MANAGED:=0}"
: "${TUNNEL_NAME:=t3-code}"
case "$CODEX_WEB_GPT_MANAGED" in
  0|1) ;;
  *) echo "CODEX_WEB_GPT_MANAGED must be '0' or '1', got '$CODEX_WEB_GPT_MANAGED'"; exit 1 ;;
esac

# --- b. tunnel (SIGTERM, honor 30s grace, force with a second signal) ---
if [ "$T3_ONLY" = 0 ]; then
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
else
  echo "leaving tunnel $TUNNEL_NAME running (T3-only stop)"
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

if [ "$T3_ONLY" = 1 ]; then
  echo "T3-only stop complete; CLIProxyAPI, tunnel, Docker Desktop, native Claude Code, caffeinate, and T3 Connect relays remain running"
  exit 0
fi

# --- e. Codex Web GPT (optional, same behavior with or without --all) ---
stop_codex_web_gpt() {
  [ "$CODEX_WEB_GPT_MANAGED" = 1 ] || return 0

  local app_path='' cli health_url route_url owned_pid='' ownership_status=none running_pid='' running_status record_status
  echo "disconnecting Codex Web GPT ..."

  app_path=$(codelaunch_codex_web_gpt_app_path || true)
  if ! cli=$(codelaunch_codex_web_gpt_cli); then
    echo "WARNING: Codex Web GPT CLI is unavailable; leaving its route and launcher unchanged."
    return 0
  fi
  if ! codelaunch_codex_web_gpt_read_route_status "$cli"; then
    echo "WARNING: could not inspect the Codex Web GPT route; leaving its launcher running."
    [ -z "$CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL" ] || echo "  $CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL"
    return 0
  fi
  if [ "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_INSTALLED" != true ]; then
    echo "WARNING: Codex Web GPT integration is not set up; nothing was disconnected or uninstalled."
    return 0
  fi
  if [ -n "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_ERRORS" ]; then
    echo "WARNING: Codex Web GPT route state is inconsistent; leaving its launcher running."
    echo "  $CODELAUNCH_CODEX_WEB_GPT_ROUTE_ERRORS"
    return 0
  fi
  if ! health_url=$(codelaunch_codex_web_gpt_health_url "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_URL"); then
    echo "WARNING: Codex Web GPT reported a non-loopback or invalid route; leaving it unchanged."
    return 0
  fi
  route_url=$CODELAUNCH_CODEX_WEB_GPT_ROUTE_URL

  if [ "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_ACTIVE" = true ]; then
    if ! codelaunch_codex_web_gpt_set_route "$cli" disconnect; then
      echo "WARNING: Codex Web GPT route disconnect failed; leaving the launcher running so native Codex is not stranded on dead loopback."
      [ -z "$CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL" ] || echo "  $CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL"
      return 0
    fi
  fi
  if ! codelaunch_codex_web_gpt_read_route_status "$cli" \
    || [ "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_INSTALLED" != true ] \
    || [ "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_ACTIVE" != false ] \
    || [ "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_URL" != "$route_url" ] \
    || [ -n "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_ERRORS" ]; then
    echo "WARNING: Codex Web GPT route did not verify as disconnected; leaving the launcher running."
    return 0
  fi
  echo "Codex Web GPT route disconnected; native Codex routing restored"

  if [ -z "$app_path" ]; then
    echo "Codex Web GPT app is not installed; route restoration is complete"
    return 0
  fi

  if codelaunch_codex_web_gpt_record_pid; then
    owned_pid=$CODELAUNCH_CODEX_WEB_GPT_PID
    # A dead PID and one recycled to another process are both stale, not a conflict.
    if codelaunch_codex_web_gpt_record_matches "$owned_pid"; then
      ownership_status=owned
    else
      ownership_status=stale
    fi
  else
    record_status=$?
    if [ "$record_status" -eq 2 ]; then
      echo "WARNING: invalid Codex Web GPT ownership record; leaving the launcher running."
      return 0
    fi
  fi

  if running_pid=$(codelaunch_codex_web_gpt_running_pid "$app_path"); then
    if [ "$ownership_status" = stale ]; then
      echo "WARNING: stale Codex Web GPT ownership record conflicts with a running launcher; leaving it up."
      return 0
    fi
    if [ "$ownership_status" != owned ]; then
      echo "Codex Web GPT launcher is running but was not started by CodeLaunch (PID $running_pid) - leaving it up"
      return 0
    fi
    if [ "$owned_pid" != "$running_pid" ]; then
      echo "WARNING: Codex Web GPT ownership does not match the running launcher; leaving it up."
      return 0
    fi
  else
    running_status=$?
    if [ "$running_status" -eq 2 ]; then
      echo "WARNING: multiple Codex Web GPT launcher processes found; leaving them unchanged."
      return 0
    fi
    if [ "$ownership_status" = stale ]; then
      if codelaunch_codex_web_gpt_health_reachable "$health_url"; then
        echo "WARNING: recorded Codex Web GPT launcher is gone but its local runtime still answers; ownership retained."
        return 0
      fi
      if codelaunch_codex_web_gpt_clear_record; then
        echo "cleared stale Codex Web GPT ownership after confirming the launcher and runtime are gone"
      else
        echo "WARNING: stale Codex Web GPT ownership record could not be cleared"
      fi
      return 0
    fi
    echo "Codex Web GPT launcher is not running"
    return 0
  fi

  if ! codelaunch_codex_web_gpt_record_matches "$owned_pid"; then
    echo "WARNING: Codex Web GPT ownership changed before quit; leaving the launcher running."
    return 0
  fi
  echo "quitting CodeLaunch-owned Codex Web GPT (PID $owned_pid) ..."
  if ! /usr/bin/osascript -e 'tell application id "dev.codexwebgpt.launcher" to quit'; then
    echo "WARNING: Codex Web GPT did not accept the application quit request; ownership retained for retry."
    return 0
  fi

  for _ in $(seq 1 60); do
    if ! kill -0 "$owned_pid" 2>/dev/null; then break; fi
    if ! codelaunch_codex_web_gpt_record_matches "$owned_pid"; then
      # The quit can land between the liveness check above and this recheck.
      kill -0 "$owned_pid" 2>/dev/null || break
      echo "WARNING: Codex Web GPT PID identity changed during shutdown; ownership retained and no signal was sent."
      return 0
    fi
    sleep 1
  done
  if kill -0 "$owned_pid" 2>/dev/null; then
    echo "WARNING: Codex Web GPT is still running after 60s; it may be draining active work."
    echo "  No force kill was attempted. Ownership is retained for a later ./stop.sh retry."
    return 0
  fi
  if codelaunch_codex_web_gpt_health_reachable "$health_url"; then
    echo "WARNING: Codex Web GPT launcher exited but its local runtime is still healthy; ownership retained for investigation."
    return 0
  fi
  if codelaunch_codex_web_gpt_clear_record; then
    echo "CodeLaunch-owned Codex Web GPT quit cleanly"
  else
    echo "WARNING: Codex Web GPT quit, but its ownership record could not be cleared"
  fi
}
stop_codex_web_gpt

# --- f. proxy (only if docker reachable) ---
if docker info >/dev/null 2>&1; then
  echo "stopping proxy ..."
  ./cliproxy/stop.sh || true
else
  echo "docker not reachable - skipping proxy stop"
fi

if [ "$ALL" = 1 ]; then
  # --- g. Docker Desktop (guarded, nonfatal) ---
  if command -v docker >/dev/null 2>&1 && docker desktop --help >/dev/null 2>&1; then
    echo "stopping Docker Desktop ..."
    docker desktop stop || echo "WARNING: Docker Desktop stop failed; leaving it running"
  else
    echo "WARNING: Docker Desktop CLI unavailable; leaving it running"
  fi

  # --- h. CodeLaunch-owned caffeinate only ---
  # start.sh reuses a pre-existing caffeinate without claiming it, so anything we did not record stays up.
  caffeinate_pid=''
  caffeinate_left=''
  if caffeinate_pid=$(codelaunch_caffeinate_owned_pid); then
    kill "$caffeinate_pid" 2>/dev/null || true
    for _ in $(seq 1 10); do
      kill -0 "$caffeinate_pid" 2>/dev/null || break
      sleep 1
    done
    # Re-check before SIGKILL, since the PID could have been recycled during the grace period.
    if codelaunch_caffeinate_record_matches "$caffeinate_pid"; then
      kill -9 "$caffeinate_pid" 2>/dev/null || true
    fi
    if ! kill -0 "$caffeinate_pid" 2>/dev/null; then
      codelaunch_caffeinate_clear_record
      echo "CodeLaunch-owned caffeinate stopped"
    else
      caffeinate_left=$caffeinate_pid
      echo "WARNING: CodeLaunch-owned caffeinate is still running (PID $caffeinate_pid)"
      echo "  Stop it with: kill $caffeinate_pid"
    fi
  else
    caffeinate_status=$?
    unowned=$(codelaunch_caffeinate_exact_pids | tr '\n' ' ')
    unowned=${unowned% }
    case "$unowned" in
      '')   unowned_label='' ;;
      *\ *) unowned_label="PIDs $unowned" ;;
      *)    unowned_label="PID $unowned" ;;
    esac
    if [ "$caffeinate_status" -eq 1 ]; then
      if [ -n "$unowned" ]; then
        caffeinate_left=$unowned
        echo "caffeinate -dims is running but not owned by CodeLaunch ($unowned_label) - leaving it up"
        echo "  Stop it with: kill $unowned"
      else
        echo "no CodeLaunch-owned caffeinate running"
      fi
    else
      caffeinate_left=${unowned:-unknown}
      echo "WARNING: invalid caffeinate ownership record; leaving caffeinate running"
      [ -z "$unowned" ] || echo "  Running caffeinate -dims ($unowned_label) - stop it with: kill $unowned"
    fi
  fi
  remaining="native Claude Code sessions and T3 Connect relays"
  [ -z "$caffeinate_left" ] || remaining="$remaining, plus caffeinate ($caffeinate_left)"
  echo "$remaining remain running"
else
  # --- g. left running on purpose ---
  echo "left running: Docker Desktop + daemon, native Claude Code sessions, caffeinate, T3 Connect relays"
  echo "Use ./stop.sh --all to also stop Docker Desktop and CodeLaunch-owned caffeinate."
fi
