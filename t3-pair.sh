#!/usr/bin/env bash
# Ensures the T3 backend matches T3_BIND, then mints a one-time pairing token.
#
#   ./t3-pair.sh            # 15m token (default)
#   ./t3-pair.sh 5m         # custom TTL (any t3 --ttl form: 5m, 1h, 30d)
#   ./t3-pair.sh --check-only    # verify T3_CHANNEL vs the desktop app, then exit
#   ./t3-pair.sh --ensure-only   # ensure the backend, then exit
#
# Custom mode only. T3 Connect owns sign-in in connect mode, so there is nothing
# here to pair; the token URL points at the tunnel in custom/full and at this
# machine in custom/direct.
#
# T3_CHANNEL must match the installed desktop app's channel, since both share the ~/.t3 store and a mismatch can break it. Escape hatch: T3_CHANNEL_SKIP_CHECK=1.
set -euo pipefail
umask 077
cd "$(dirname "$0")"
. ./scripts/env.sh
. ./scripts/pairing.sh

usage() {
  cat <<'EOF'
Usage: ./t3-pair.sh [-d|--detached] [TTL]
       ./t3-pair.sh --check-only
       ./t3-pair.sh --ensure-only
EOF
}

MODE=pair
DETACHED=0
TTL=15m
TTL_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d|--detached)
      [ "$MODE" = pair ] && [ "$DETACHED" = 0 ] || { echo "invalid option combination" >&2; usage >&2; exit 2; }
      DETACHED=1; shift
      ;;
    --check-only|--ensure-only)
      [ "$MODE" = pair ] && [ "$TTL_SET" = 0 ] && [ "$DETACHED" = 0 ] || { echo "invalid option combination" >&2; usage >&2; exit 2; }
      case "$1" in
        --check-only) MODE=check ;;
        --ensure-only) MODE=ensure ;;
      esac
      shift
      [ "$#" -eq 0 ] || { echo "special mode accepts no other arguments" >&2; usage >&2; exit 2; }
      ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      [ "$MODE" = pair ] && [ "$TTL_SET" = 0 ] || { echo "unexpected argument: $1" >&2; usage >&2; exit 2; }
      TTL=$1; TTL_SET=1; shift
      ;;
  esac
done

codelaunch_private_file .env
codelaunch_load_env --optional T3_MODE T3_CUSTOM_ACCESS
: "${T3_MODE:=connect}"
case "$T3_MODE" in
  connect)
    echo "T3_MODE=connect - T3 Connect owns sign-in, so CodeLaunch mints no pairing token."
    echo "  Sign in at https://app.t3.codes or in the T3 Code app on iOS."
    exit 1
    ;;
  custom) ;;
  *) echo "T3_MODE must be 'connect' or 'custom', got '$T3_MODE'"; exit 1 ;;
esac
: "${T3_CUSTOM_ACCESS:=direct}"
case "$T3_CUSTOM_ACCESS" in
  direct|full) ;;
  *) echo "T3_CUSTOM_ACCESS must be 'direct' or 'full', got '$T3_CUSTOM_ACCESS'"; exit 1 ;;
esac
RUN_MODE="custom-$T3_CUSTOM_ACCESS"

codelaunch_load_env T3_PORT T3_BIND T3_CHANNEL T3_CHANNEL_SKIP_CHECK
codelaunch_require_env T3_PORT

# The public hostname is Cloudflare-only configuration, so it is read in
# custom/full alone; direct pairing points at this machine.
if [ "$T3_CUSTOM_ACCESS" = full ]; then
  codelaunch_load_env T3_HOSTNAME
  PAIR_LABEL=Tunnel
  PAIR_TOKEN_LABEL=cloudflare-browser
  if [ "$MODE" = pair ]; then
    codelaunch_require_env T3_HOSTNAME
    PAIR_BASE_URL="https://$T3_HOSTNAME"
  fi
else
  PAIR_LABEL=Local
  PAIR_TOKEN_LABEL=direct-browser
  PAIR_BASE_URL="http://127.0.0.1:$T3_PORT"
fi

: "${T3_CHANNEL:=latest}"
case "$T3_CHANNEL" in
  nightly|latest) ;;
  *) echo "T3_CHANNEL must be 'nightly' or 'latest', got '$T3_CHANNEL'"; exit 1 ;;
esac
PKG="t3@$T3_CHANNEL"

: "${T3_BIND:=loopback}"
case "$T3_BIND" in
  loopback) BIND_HOST=127.0.0.1 ;;
  all)      BIND_HOST=0.0.0.0 ;;
  *) echo "T3_BIND must be 'loopback' or 'all', got '$T3_BIND'"; exit 1 ;;
esac

listening() { lsof -nP -iTCP:"$T3_PORT" -sTCP:LISTEN 2>/dev/null; }

# --- channel guard ---------------------------------------------------------
codelaunch_t3_channel_guard "$T3_CHANNEL" "$T3_PORT" || exit 1

# Callers that only want the guard, like t3-start.sh's pre-flight check, stop here before anything starts.
if [ "$MODE" = check ]; then exit 0; fi

codelaunch_prepare_runtime
T3_SERVE_LOG="$CODELAUNCH_RUNTIME_DIR/t3-serve.log"

if [ "$MODE" = pair ] && ! command -v jq >/dev/null 2>&1; then
  echo "missing required dependency: jq"
  echo "Install it with: brew install jq"
  exit 1
fi

if listening >/dev/null; then
  echo "T3 backend already listening on :$T3_PORT (reusing)"
else
  echo "starting headless T3 backend ($PKG) on $BIND_HOST:$T3_PORT ..."
  codelaunch_t3_serve_start "$RUN_MODE" "$PKG" "$T3_SERVE_LOG" \
    --host "$BIND_HOST" --port "$T3_PORT" >/dev/null || exit 1
  echo "backend up"
fi

listener_rows=$(listening || true)
listener_lines=$(printf '%s\n' "$listener_rows" | tail -n +2)
# A dual-stack bind prints one row per socket, so collapse to the distinct owning PIDs.
listener_pids=$(printf '%s\n' "$listener_lines" | awk 'NF { print $2 }' | sort -u)
live_pids=''
for p in $listener_pids; do
  ps -p "$p" -o command= >/dev/null 2>&1 && live_pids="${live_pids:+$live_pids }$p"
done
if [ -z "$live_pids" ]; then
  echo "REFUSING: no live backend process owns :$T3_PORT."
  exit 1
fi
case "$live_pids" in
  *\ *) pid_label="PIDs $live_pids"; echo "note: multiple processes are listening on :$T3_PORT" ;;
  *)    pid_label="PID $live_pids" ;;
esac
if [ "$T3_BIND" = loopback ]; then
  non_loopback=$(printf '%s\n' "$listener_lines" | grep -vE '(^|[[:space:]])(127\.0\.0\.1|\[::1\]|::1):' || true)
  if [ -n "$non_loopback" ]; then
    echo "REFUSING: T3_BIND=loopback but the backend is bound wider. Fix before pairing."
    echo "  Restart the backend with ./t3-stop.sh && ./t3-start.sh"
    echo "$non_loopback"
    exit 1
  fi
  echo "backend check ok ($pid_label, loopback only)"
else
  if ! printf '%s\n' "$listener_lines" | grep -qE '(^|[[:space:]])(\*|0\.0\.0\.0):'"$T3_PORT"'([[:space:]]|$)'; then
    echo "REFUSING: T3_BIND=all but nothing is listening on the wildcard address."
    echo "  Restart the backend with ./t3-stop.sh && ./t3-start.sh"
    printf '%s\n' "$listener_lines"
    exit 1
  fi
  echo "backend check ok ($pid_label, wildcard bind)"
fi

if [ "$MODE" = ensure ]; then exit 0; fi

echo "minting pairing token (ttl $TTL) ..."
if ! pairing_json=$(npx --yes "$PKG" auth pairing create \
  --ttl "$TTL" \
  --label "$PAIR_TOKEN_LABEL" \
  --base-url "$PAIR_BASE_URL" \
  --json); then
  echo "T3 pairing command failed."
  exit 1
fi

if ! printf '%s' "$pairing_json" | jq -e '
  type == "object" and
  (.credential | type == "string" and length > 0) and
  (.pairUrl | type == "string" and length > 0) and
  (.expiresAt | (type == "string" or type == "number"))
' >/dev/null 2>&1; then
  echo "T3 pairing command returned invalid or incomplete JSON."
  echo "Expected credential, pairUrl, and expiresAt fields."
  exit 1
fi

credential=$(printf '%s' "$pairing_json" | jq -r '.credential')
pair_url=$(printf '%s' "$pairing_json" | jq -r '.pairUrl')
expires_at=$(printf '%s' "$pairing_json" | jq -r '.expiresAt')

codelaunch_pairing_present "$credential" "$expires_at" "$pair_url" "$T3_PORT" "$T3_BIND" "$DETACHED" "$PAIR_LABEL"
