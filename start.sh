#!/usr/bin/env bash
# Brings the remote-agent stack up, reusing whatever is already running.
# Prints a one-time T3 pairing token and the main URL when done.
#
#   ./start.sh            # 15m pairing token (default)
#   ./start.sh 5m         # custom TTL, passed to t3-pair.sh
#   ./start.sh --detached # print pairing summary without the menu
#
# Order: prereqs, caffeinate, Docker, Codex token, proxy, T3 backend, tunnel, token.
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
codelaunch_load_env T3_HOSTNAME T3_PORT T3_BIND T3_CHANNEL T3_CHANNEL_SKIP_CHECK TUNNEL_NAME
codelaunch_require_env T3_HOSTNAME T3_PORT TUNNEL_NAME
: "${T3_BIND:=loopback}"
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

# --- g. T3 backend ---
echo "ensuring T3 backend ..."
./t3-pair.sh --ensure-only

# --- h. tunnel ---
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

# --- i. one-time pairing token ---
echo "minting pairing token ..."
PAIR_ARGS=("$TTL")
[ "$DETACHED" = 1 ] && PAIR_ARGS+=(--detached)
./t3-pair.sh "${PAIR_ARGS[@]}"
