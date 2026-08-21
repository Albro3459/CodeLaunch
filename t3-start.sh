#!/usr/bin/env bash
# Owns the T3 lifecycle. Selects T3 Connect or the custom hosting path from
# T3_MODE and performs an idempotent, fully detached start.
#
#   ./t3-start.sh              # start T3 in the configured mode
#   ./t3-start.sh 5m           # custom modes: pairing token TTL
#   ./t3-start.sh --detached   # custom modes: pairing summary without the menu
#
# Runs standalone. T3_ENABLED gates whether start.sh calls this; running it
# directly starts T3 regardless.
#
# connect       -> T3 Connect owns remote access and activity publishing.
# custom/direct -> plain server, no managed link and no tunnel.
# custom/full   -> plain server plus the CodeLaunch Cloudflare Access/Tunnel.
set -euo pipefail
umask 077
cd "$(dirname "$0")"
. ./scripts/env.sh

usage() {
  cat <<'EOF'
Usage: ./t3-start.sh [-d|--detached] [TTL]
       ./t3-start.sh -h|--help
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

# --- a. mode selection -----------------------------------------------------
# Only the mode-selection variables are read here. Connect mode must never load,
# validate, or export the custom networking configuration.
codelaunch_private_file .env
codelaunch_load_env --optional T3_MODE T3_CUSTOM_ACCESS T3_CHANNEL T3_CHANNEL_SKIP_CHECK
: "${T3_MODE:=connect}"
: "${T3_CHANNEL:=latest}"
case "$T3_MODE" in
  connect|custom) ;;
  *) echo "T3_MODE must be 'connect' or 'custom', got '$T3_MODE'"; exit 1 ;;
esac
case "$T3_CHANNEL" in
  nightly|latest) ;;
  *) echo "T3_CHANNEL must be 'nightly' or 'latest', got '$T3_CHANNEL'"; exit 1 ;;
esac
PKG="t3@$T3_CHANNEL"

if [ "$T3_MODE" = custom ]; then
  : "${T3_CUSTOM_ACCESS:=direct}"
  case "$T3_CUSTOM_ACCESS" in
    direct|full) ;;
    *) echo "T3_CUSTOM_ACCESS must be 'direct' or 'full', got '$T3_CUSTOM_ACCESS'"; exit 1 ;;
  esac
  RUN_MODE="custom-$T3_CUSTOM_ACCESS"
else
  RUN_MODE=connect
  if [ "$TTL_SET" = 1 ] || [ "$DETACHED" = 1 ]; then
    echo "note: pairing options are ignored in connect mode - T3 Connect handles sign-in"
  fi
fi

command -v npx >/dev/null 2>&1 || { echo "missing prerequisite on PATH: npx"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "missing prerequisite on PATH: jq"; echo "Install it with: brew install jq"; exit 1; }

codelaunch_prepare_runtime
T3_SERVE_LOG="$CODELAUNCH_RUNTIME_DIR/t3-serve.log"
CLOUDFLARED_LOG="$CODELAUNCH_RUNTIME_DIR/cloudflared-t3.log"

# --- b. already-running server ---------------------------------------------
# An owned server is reused as-is: its log still holds this boot's reconcile
# result, so it must not be truncated by a second start.
# Called directly, not through $( ): the recorded mode only reaches this shell
# when the function does not run in a subshell.
owned_pid=''
if codelaunch_t3_owned_pid >/dev/null; then
  owned_pid=$CODELAUNCH_T3_PID
  if [ "$CODELAUNCH_T3_MODE" = "$RUN_MODE" ]; then
    echo "T3 server already owned by CodeLaunch (reusing PID $owned_pid, mode $CODELAUNCH_T3_MODE)"
  else
    echo "REFUSING: a CodeLaunch-owned T3 server is running in '$CODELAUNCH_T3_MODE' mode (PID $owned_pid)."
    echo "  Stop it before starting '$RUN_MODE': ./t3-stop.sh"
    exit 1
  fi
else
  owned_status=$?
  [ "$owned_status" -ne 2 ] || {
    echo "REFUSING: invalid T3 ownership record." >&2
    echo "  Inspect and remove $HOME/.codelaunch/run/t3-serve.pid, then rerun ./t3-start.sh." >&2
    exit 1
  }
  owned_pid=''
fi

if [ "$RUN_MODE" = connect ]; then
  # --- c. connect: channel guard -------------------------------------------
  codelaunch_t3_channel_guard "$T3_CHANNEL" || exit 1

  # --- d. connect: authentication and environment link ---------------------
  # `connect status --json` reports whether a link exists, but not whether it is
  # a full or a publish-only one. The mode lives in this one secret file; a
  # missing or unreadable file is never treated as publish-only, so a failed
  # read can never cause an unlink.
  DESIRED_LINK_FILE="${T3CODE_HOME:-$HOME/.t3}/userdata/secrets/cloud-cli-desired-link.bin"

  connect_status() {
    local json
    CONNECT_DESIRED=''
    CONNECT_AUTHENTICATED=''
    CONNECT_LINKED=''
    json=$(npx --yes "$PKG" connect status --json 2>/dev/null) || return 1
    printf '%s' "$json" | jq -e '
      type == "object" and
      (.desired | type == "boolean") and
      (.authenticated | type == "boolean") and
      (.linked | type == "boolean")
    ' >/dev/null 2>&1 || return 1
    CONNECT_DESIRED=$(printf '%s' "$json" | jq -r '.desired')
    CONNECT_AUTHENTICATED=$(printf '%s' "$json" | jq -r '.authenticated')
    CONNECT_LINKED=$(printf '%s' "$json" | jq -r '.linked')
  }

  connect_link_is_publish_only() {
    local value
    [ -f "$DESIRED_LINK_FILE" ] || return 1
    [ ! -L "$DESIRED_LINK_FILE" ] || return 1
    value=$(cat "$DESIRED_LINK_FILE" 2>/dev/null) || return 1
    [ "$value" = publish_only ]
  }

  connect_require_tty() {
    [ -t 0 ] && [ -t 1 ] && return 0
    echo "T3 Connect setup needs a TTY - it prompts for an out-of-band authorization code."
    echo "Run these on the host, then rerun ./t3-start.sh:"
    echo "  npx --yes $PKG connect login --headless"
    echo "  npx --yes $PKG connect link --headless"
    exit 1
  }

  if ! connect_status; then
    echo "WARNING: could not read T3 Connect status - starting the server without reconciling the link."
    echo "  Check it by hand with: npx --yes $PKG connect status"
  else
    relink=0
    if [ "$CONNECT_AUTHENTICATED" != true ]; then
      echo "T3 Connect is not authorized on this machine - signing in ..."
      connect_require_tty
      npx --yes "$PKG" connect login --headless
      relink=1
    elif [ "$CONNECT_DESIRED" != true ]; then
      echo "T3 Connect is authorized but this environment is not linked - linking ..."
      relink=1
    elif connect_link_is_publish_only; then
      echo "T3 Connect is linked for publishing only - replacing it with a full Connect link ..."
      connect_require_tty
      npx --yes "$PKG" connect unlink
      relink=1
    fi
    if [ "$relink" = 1 ]; then
      connect_require_tty
      npx --yes "$PKG" connect link --headless
      connect_status || true
    fi
    if [ "$CONNECT_LINKED" = true ]; then
      echo "T3 Connect link provisioned"
    else
      echo "T3 Connect link pending - the server provisions it on startup"
    fi
  fi

  # --- e. connect: server --------------------------------------------------
  if [ -z "$owned_pid" ]; then
    unowned=$(codelaunch_t3_unowned_pids | tr '\n' ' ')
    unowned=${unowned% }
    if [ -n "$unowned" ]; then
      echo "a headless T3 server is already running but was not started by CodeLaunch (PID $unowned) - reusing it"
      echo "  ./t3-stop.sh will leave it alone. Stop it yourself to hand the lifecycle to CodeLaunch."
    else
      echo "starting T3 server ($PKG) ..."
      owned_pid=$(codelaunch_t3_serve_start "$RUN_MODE" "$PKG" "$T3_SERVE_LOG") || exit 1
      echo "T3 server up (owned PID $owned_pid)"
      echo "log: $T3_SERVE_LOG"
    fi
  fi

  # --- f. connect: link health --------------------------------------------
  # Only the log of a server we own describes this boot.
  if [ -n "$owned_pid" ]; then
    case "$(codelaunch_t3_wait_reconcile "$T3_SERVE_LOG" 45)" in
      ok)
        echo "T3 Connect link reconciled this boot - this machine is reachable"
        ;;
      failed)
        echo "WARNING: T3 Connect link reconcile FAILED this boot - this machine is NOT reachable through T3 Connect."
        echo "  The stored credential no longer refreshes, or the relay was unreachable at startup."
        echo "  'connect status' will still say 'provisioned' - it reads stale local files."
        echo "  Fix: npx --yes $PKG connect login --headless, then ./t3-stop.sh && ./t3-start.sh"
        echo "  Detail: grep -A4 '$CODELAUNCH_T3_RECONCILE_FAIL' $T3_SERVE_LOG"
        ;;
      *)
        echo "note: no T3 Connect reconcile result in $T3_SERVE_LOG after 45s - link health unknown"
        ;;
    esac
  fi

  printf '\n============================================================\n'
  printf 'T3 CONNECT\n'
  printf '============================================================\n'
  printf 'Sign in with your T3 account from any device:\n'
  printf '  https://app.t3.codes\n'
  printf '  the T3 Code app on iOS\n\n'
  printf 'No pairing code, tunnel, or hostname is involved - T3 Connect\n'
  printf 'owns remote access and activity publishing for this machine.\n'
  exit 0
fi

# --- g. custom: networking configuration -----------------------------------
codelaunch_load_env T3_PORT T3_BIND
codelaunch_require_env T3_PORT
: "${T3_BIND:=loopback}"
case "$T3_BIND" in
  loopback) BIND_HOST=127.0.0.1 ;;
  all)      BIND_HOST=0.0.0.0 ;;
  *) echo "T3_BIND must be 'loopback' or 'all', got '$T3_BIND'"; exit 1 ;;
esac

if [ "$T3_CUSTOM_ACCESS" = full ]; then
  codelaunch_load_env T3_HOSTNAME TUNNEL_NAME
  codelaunch_require_env T3_HOSTNAME TUNNEL_NAME
  command -v cloudflared >/dev/null 2>&1 || { echo "missing prerequisite on PATH: cloudflared"; exit 1; }
fi

# Direct access is not VPN-only. A wildcard bind is reachable from anything that
# can route to this machine, which on a home or office network is every device
# on the same Wi-Fi.
if [ "$T3_BIND" = all ]; then
  echo "WARNING: T3_BIND=all exposes :$T3_PORT on every interface - LAN/Wi-Fi devices can"
  echo "  reach it too, not just your VPN. The only gate is the pairing code."
elif [ "$T3_CUSTOM_ACCESS" = direct ]; then
  echo "note: T3_BIND=loopback - only this machine can reach :$T3_PORT."
  echo "  Set T3_BIND=all in .env for LAN/Wi-Fi and VPN access."
fi

./t3-pair.sh --check-only

# Declared publishing intent vs what is actually on disk. Warn only - a notification
# setting should not block the stack. Health is checked after the backend is up.
./t3-publish.sh --check-only

# --- h. custom: backend ----------------------------------------------------
if [ -z "$owned_pid" ]; then
  if lsof -nP -iTCP:"$T3_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "T3 backend already listening on :$T3_PORT but not started by CodeLaunch - reusing it"
    echo "  ./t3-stop.sh will leave it alone."
  else
    echo "starting headless T3 backend ($PKG) on $BIND_HOST:$T3_PORT ..."
    owned_pid=$(codelaunch_t3_serve_start "$RUN_MODE" "$PKG" "$T3_SERVE_LOG" --host "$BIND_HOST" --port "$T3_PORT") || exit 1
    echo "T3 backend up (owned PID $owned_pid)"
    echo "log: $T3_SERVE_LOG"
  fi
fi

# Verifies the live bind matches T3_BIND before anything is exposed.
./t3-pair.sh --ensure-only

# --- i. custom/full: tunnel ------------------------------------------------
if [ "$T3_CUSTOM_ACCESS" = full ]; then
  if [ -n "$(codelaunch_tunnel_pids "$TUNNEL_NAME")" ]; then
    echo "tunnel $TUNNEL_NAME already running (reusing)"
  else
    echo "starting tunnel $TUNNEL_NAME ..."
    codelaunch_reset_private_log "$CLOUDFLARED_LOG"
    nohup cloudflared tunnel run "$TUNNEL_NAME" </dev/null >"$CLOUDFLARED_LOG" 2>&1 &
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
  codelaunch_t3_write_tunnel_state "$TUNNEL_NAME" \
    || echo "WARNING: tunnel ownership could not be recorded; ./t3-stop.sh will leave it running"
fi

# --- j. custom: publishing health ------------------------------------------
# Runs after the tunnel so the backend's reconcile has had that time to land.
./t3-publish.sh --verify-only

# --- k. custom: one-time pairing token -------------------------------------
echo "minting pairing token ..."
PAIR_ARGS=("$TTL")
[ "$DETACHED" = 1 ] && PAIR_ARGS+=(--detached)
./t3-pair.sh "${PAIR_ARGS[@]}"
