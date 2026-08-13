#!/usr/bin/env bash
# Brings the remote-agent stack up, reusing whatever is already running.
# Prints a one-time T3 pairing token and the main URL when done.
#
#   ./start.sh            # 15m pairing token (default)
#   ./start.sh 5m         # custom TTL, passed to t3-pair.sh
#   ./start.sh --detached # print pairing summary without the menu
#
# Order: prereqs, caffeinate, Docker, Codex token, proxy, Codex Web GPT, T3 backend, tunnel, publish check, token.
# See SETUP.md "Step 5" and QUICK-SETUP.md.
set -euo pipefail
umask 077
cd "$(dirname "$0")"
. ./scripts/env.sh

usage() {
  cat <<'EOF'
Usage: ./start.sh [-d|--detached] [TTL]
       ./start.sh -h|--help
EOF
}

TTL=15m
DETACHED=0
TTL_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d|--detached)
      [ "$DETACHED" = 0 ] || { echo "duplicate detached option" >&2; usage >&2; exit 2; }
      DETACHED=1; shift
      ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      [ "$TTL_SET" = 0 ] || { echo "too many arguments" >&2; usage >&2; exit 2; }
      TTL=$1; TTL_SET=1; shift
      ;;
  esac
done

# --- a. env ---
codelaunch_private_file .env
codelaunch_load_env T3_HOSTNAME T3_PORT T3_BIND T3_CHANNEL T3_CHANNEL_SKIP_CHECK T3_PUBLISH_ACTIVITY CODEX_WEB_GPT_MANAGED TUNNEL_NAME
codelaunch_require_env T3_HOSTNAME T3_PORT TUNNEL_NAME
: "${T3_BIND:=loopback}"
: "${CODEX_WEB_GPT_MANAGED:=0}"
case "$CODEX_WEB_GPT_MANAGED" in
  0|1) ;;
  *) echo "CODEX_WEB_GPT_MANAGED must be '0' or '1', got '$CODEX_WEB_GPT_MANAGED'"; exit 1 ;;
esac
codelaunch_codex_desktop_preflight "$CODEX_WEB_GPT_MANAGED" || exit 1
if [ "$T3_BIND" = all ]; then
  echo "WARNING: T3_BIND=all exposes :$T3_PORT to your LAN/VPN; pairing code only"
fi
codelaunch_private_file cliproxy/config.yaml
codelaunch_private_tree cliproxy/auth
codelaunch_prepare_runtime
CLOUDFLARED_LOG="$CODELAUNCH_RUNTIME_DIR/cloudflared-t3.log"
T3_SERVE_LOG="$CODELAUNCH_RUNTIME_DIR/t3-serve.log"
export T3_SERVE_LOG

# --- b. prereqs (collect all missing, fail once) ---
missing=()
for c in docker cloudflared claude claudex npx jq; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "missing prerequisites on PATH: ${missing[*]}"; exit 1
fi

# T3_CHANNEL must match the installed desktop app, checked early so a mismatch fails fast instead of after a full bring-up.
./t3-pair.sh --check-only

# Declared publishing intent vs what is actually on disk. Warn only - a notification
# setting should not block the stack. Health is checked after the backend is up.
./t3-publish.sh --check-only

# --- c. power + keep-awake ---
if pmset -g batt | grep -q 'AC Power'; then
  echo "on AC power"
else
  echo "WARNING: not on AC power - sleep assertions release when unplugged (see QUICK-SETUP.md)"
fi
caffeinate_pid=''
if caffeinate_pid=$(codelaunch_caffeinate_owned_pid); then
  echo "caffeinate -dims already owned by CodeLaunch (reusing PID $caffeinate_pid)"
else
  caffeinate_status=$?
  [ "$caffeinate_status" -ne 2 ] || { echo "REFUSING: invalid caffeinate ownership record" >&2; exit 1; }
  existing_caffeinate=$(codelaunch_caffeinate_exact_pids | head -1 || true)
  if [ -n "$existing_caffeinate" ]; then
    echo "caffeinate -dims already running (reusing without claiming PID $existing_caffeinate)"
  else
    nohup caffeinate -dims >/dev/null 2>&1 &
    caffeinate_pid=$!
    caffeinate_verified=0
    for _ in $(seq 1 20); do
      kill -0 "$caffeinate_pid" 2>/dev/null || break
      if codelaunch_caffeinate_exact_command "$caffeinate_pid"; then
        caffeinate_verified=1
        break
      fi
      sleep 0.05
    done
    if [ "$caffeinate_verified" -ne 1 ]; then
      echo "caffeinate -dims failed verification" >&2
      exit 1
    fi
    codelaunch_caffeinate_write_pid "$caffeinate_pid"
    echo "started caffeinate -dims (display/idle/system awake while on power)"
  fi
fi

# --- d. Docker ---
if docker info >/dev/null 2>&1; then
  echo "docker up"
else
  echo "starting Docker Desktop ..."
  # --help just checks the docker desktop CLI exists, since status can exit non-zero when Desktop is simply stopped.
  if docker desktop --help >/dev/null 2>&1; then
    docker desktop start --timeout 120 || true
  else
    open -g -j -a Docker
  fi
  echo "waiting for docker daemon (up to 120s) ..."
  for _ in $(seq 1 120); do
    docker info >/dev/null 2>&1 && break
    sleep 1
  done
  docker info >/dev/null 2>&1 || { echo "docker did not come up within 120s"; exit 1; }
  echo "docker up"
fi

# --- e. Codex OAuth token ---
# Valid while now < the ISO-8601 `expired` field (carries a tz offset).
codex_remaining() {
  python3 - "$1" <<'PY'
import sys, json
from datetime import datetime, timezone
try:
    exp = datetime.fromisoformat(json.load(open(sys.argv[1]))["expired"])
except Exception:
    sys.exit(2)
now = datetime.now(timezone.utc)
if now >= exp:
    sys.exit(1)
rem = exp - now
print(f"{rem.days}d {rem.seconds // 3600}h")
PY
}
newest_codex=$(ls -t cliproxy/auth/codex-*.json 2>/dev/null | head -1 || true)
need_login=0
if [ -z "$newest_codex" ]; then
  need_login=1
elif rem=$(codex_remaining "$newest_codex"); then
  echo "codex token valid ($rem left)"
else
  need_login=1
fi
if [ "$need_login" = 1 ]; then
  if [ -t 0 ]; then
    echo "codex token missing or expired - launching ./cliproxy/login.sh (opens the host browser) ..."
    ./cliproxy/login.sh
    newest_codex=$(ls -t cliproxy/auth/codex-*.json 2>/dev/null | head -1 || true)
    if [ -n "$newest_codex" ] && rem=$(codex_remaining "$newest_codex"); then
      echo "codex token valid ($rem left)"
    else
      echo "still no valid codex token after login"; exit 1
    fi
  else
    echo "codex token missing or expired and no TTY - run ./cliproxy/login.sh on the host"; exit 1
  fi
fi

# --- f. proxy ---
echo "starting proxy ..."
./cliproxy/start.sh
KEY=$(grep -oE '[0-9a-f]{64}' cliproxy/config.yaml | head -1 || true)
[ -n "$KEY" ] || { echo "no local API key found in cliproxy/config.yaml"; exit 1; }
# Key goes to curl via stdin (-K -), not argv, so it never shows in ps.
if ! printf 'header = "Authorization: Bearer %s"\n' "$KEY" \
  | curl -fsS -K - http://127.0.0.1:8317/v1/models >/dev/null 2>&1; then
  echo "proxy up but local API key rejected - check cliproxy/config.yaml"; exit 1
fi
echo "proxy up and key accepted"

# --- g. Codex Web GPT (optional, nonfatal) ---
start_codex_web_gpt() {
  [ "$CODEX_WEB_GPT_MANAGED" = 1 ] || return 0

  local app_path cli health_url route_url launcher_pid='' launcher_status owned_pid='' owned_status=unowned
  local launcher_was_running=0 route_connected_here=0
  echo "ensuring Codex Web GPT ..."

  if ! app_path=$(codelaunch_codex_web_gpt_app_path); then
    echo "WARNING: Codex Web GPT is not installed; continuing without managed web-backed Codex models."
    echo "  Install and complete setup in the Codex Web GPT launcher, disable Launch at login, then rerun ./start.sh."
    return 0
  fi
  if ! cli=$(codelaunch_codex_web_gpt_cli); then
    echo "WARNING: Codex Web GPT CLI is unavailable; continuing without managed web-backed Codex models."
    echo "  Repair or reinstall the launcher, complete setup there, then rerun ./start.sh."
    return 0
  fi
  if ! codelaunch_codex_web_gpt_read_route_status "$cli"; then
    echo "WARNING: could not inspect the Codex Web GPT route; continuing without changing it."
    [ -z "$CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL" ] || echo "  $CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL"
    return 0
  fi
  if [ "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_INSTALLED" != true ]; then
    echo "WARNING: Codex Web GPT is installed but its Codex integration is not set up."
    echo "  Complete setup in the launcher, disable Launch at login, then rerun ./start.sh."
    return 0
  fi
  if [ -n "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_ERRORS" ]; then
    echo "WARNING: Codex Web GPT route state is inconsistent; continuing without changing it."
    echo "  $CODELAUNCH_CODEX_WEB_GPT_ROUTE_ERRORS"
    return 0
  fi
  if ! health_url=$(codelaunch_codex_web_gpt_health_url "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_URL"); then
    echo "WARNING: Codex Web GPT reported a non-loopback or invalid route; continuing without changing it."
    return 0
  fi
  route_url=$CODELAUNCH_CODEX_WEB_GPT_ROUTE_URL
  if owned_pid=$(codelaunch_codex_web_gpt_owned_pid); then
    owned_status=owned
  else
    launcher_status=$?
    if [ "$launcher_status" -eq 2 ]; then
      echo "WARNING: invalid Codex Web GPT ownership record; refusing to claim or launch the app."
      echo "  Inspect and remove $HOME/.codelaunch/run/codex-web-gpt.pid, then rerun ./start.sh."
      return 0
    fi
  fi

  if launcher_pid=$(codelaunch_codex_web_gpt_running_pid "$app_path"); then
    launcher_was_running=1
    if [ "$owned_status" = owned ] && [ "$owned_pid" != "$launcher_pid" ]; then
      echo "WARNING: Codex Web GPT ownership does not match the running launcher; leaving it unchanged."
      return 0
    fi
    if [ "$owned_status" = owned ]; then
      echo "Codex Web GPT launcher already owned by CodeLaunch (reusing PID $launcher_pid)"
    else
      echo "Codex Web GPT launcher already running (reusing without claiming PID $launcher_pid)"
    fi
  else
    launcher_status=$?
    if [ "$launcher_status" -eq 2 ]; then
      echo "WARNING: multiple Codex Web GPT launcher processes found; leaving them unchanged."
      return 0
    fi
    if [ "$owned_status" = owned ]; then
      echo "WARNING: recorded Codex Web GPT launcher is not the installed app; leaving it unchanged."
      return 0
    fi
  fi

  # The external CLI only changes Codex configuration. The launcher starts its
  # supervised runtime at process startup when that route is active, so a stopped
  # launcher must be connected immediately before it is opened. Any later failure
  # compensates with route disconnect so native Codex is not stranded on loopback.
  if [ "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_ACTIVE" != true ]; then
    if ! codelaunch_codex_web_gpt_set_route "$cli" connect; then
      echo "WARNING: Codex Web GPT route connect failed; continuing without managed web-backed models."
      [ -z "$CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL" ] || echo "  $CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL"
      return 0
    fi
    if ! codelaunch_codex_web_gpt_read_route_status "$cli" \
      || [ "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_INSTALLED" != true ] \
      || [ "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_ACTIVE" != true ] \
      || [ "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_URL" != "$route_url" ] \
      || [ -n "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_ERRORS" ]; then
      echo "WARNING: Codex Web GPT route did not verify after connect; attempting to restore native routing."
      codelaunch_codex_web_gpt_set_route "$cli" disconnect || true
      return 0
    fi
    route_connected_here=1
  fi

  if [ -z "$launcher_pid" ]; then
    echo "starting Codex Web GPT hidden ..."
    if ! open -g -j "$app_path" --args --hidden; then
      echo "WARNING: Codex Web GPT launcher did not open."
      if [ "$route_connected_here" = 1 ] || [ "$launcher_was_running" = 0 ]; then
        codelaunch_codex_web_gpt_set_route "$cli" disconnect || true
      fi
      return 0
    fi
    for _ in $(seq 1 30); do
      if launcher_pid=$(codelaunch_codex_web_gpt_running_pid "$app_path"); then
        break
      else
        launcher_status=$?
      fi
      [ "$launcher_status" -ne 2 ] || break
      sleep 1
    done
    if [ -z "$launcher_pid" ] || [ "${launcher_status:-0}" -eq 2 ]; then
      echo "WARNING: Codex Web GPT launcher process could not be verified."
      if [ "$route_connected_here" = 1 ] || [ "$launcher_was_running" = 0 ]; then
        codelaunch_codex_web_gpt_set_route "$cli" disconnect || true
      fi
      return 0
    fi
    if ! codelaunch_codex_web_gpt_write_pid "$launcher_pid" "$app_path/Contents/MacOS/Codex Web GPT"; then
      echo "WARNING: Codex Web GPT started, but CodeLaunch could not record exact ownership; it will be left running on stop."
      codelaunch_codex_web_gpt_clear_record || true
    else
      echo "started Codex Web GPT hidden (owned PID $launcher_pid)"
    fi
  fi

  if codelaunch_codex_web_gpt_wait_health "$health_url" 60; then
    if ! codelaunch_codex_web_gpt_doctor_ok "$cli"; then
      echo "WARNING: Codex Web GPT doctor did not verify the running setup."
      [ -z "$CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL" ] || echo "  $CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL"
    elif codelaunch_codex_web_gpt_read_route_status "$cli" \
      && [ "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_INSTALLED" = true ] \
      && [ "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_ACTIVE" = true ] \
      && [ "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_URL" = "$route_url" ] \
      && [ -z "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_ERRORS" ]; then
      echo "Codex Web GPT runtime healthy and route connected"
      return 0
    else
      echo "WARNING: Codex Web GPT became healthy, but its connected route did not verify."
    fi
  else
    echo "WARNING: Codex Web GPT runtime did not become healthy within 60s."
  fi

  if [ "$route_connected_here" = 1 ] || [ "$launcher_was_running" = 0 ]; then
    if codelaunch_codex_web_gpt_set_route "$cli" disconnect \
      && codelaunch_codex_web_gpt_read_route_status "$cli" \
      && [ "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_ACTIVE" = false ] \
      && [ -z "$CODELAUNCH_CODEX_WEB_GPT_ROUTE_ERRORS" ]; then
      echo "restored native Codex routing after Codex Web GPT startup failure"
    else
      echo "WARNING: native Codex routing could not be restored; leave the launcher running and repair its bridge in Settings."
    fi
  fi
}
start_codex_web_gpt

# --- h. T3 backend ---
echo "ensuring T3 backend ..."
./t3-pair.sh --ensure-only

# --- i. tunnel ---
if [ -n "$(codelaunch_tunnel_pids "$TUNNEL_NAME")" ]; then
  echo "tunnel $TUNNEL_NAME already running (reusing)"
else
  echo "starting tunnel $TUNNEL_NAME ..."
  codelaunch_reset_private_log "$CLOUDFLARED_LOG"
  nohup cloudflared tunnel run "$TUNNEL_NAME" >"$CLOUDFLARED_LOG" 2>&1 &
  for _ in $(seq 1 30); do
    grep -q "Registered tunnel connection" "$CLOUDFLARED_LOG" 2>/dev/null && break
    sleep 1
  done
  if ! grep -q "Registered tunnel connection" "$CLOUDFLARED_LOG" 2>/dev/null; then
    echo "tunnel did not register within 30s; last log lines:"
    tail -20 "$CLOUDFLARED_LOG"
    exit 1
  fi
  echo "tunnel registered"
fi

# --- j. publishing health ---
# Runs after the tunnel so the backend's reconcile has had that time to land.
./t3-publish.sh --verify-only

# --- k. one-time pairing token ---
echo "minting pairing token ..."
PAIR_ARGS=("$TTL")
[ "$DETACHED" = 1 ] && PAIR_ARGS+=(--detached)
./t3-pair.sh "${PAIR_ARGS[@]}"
