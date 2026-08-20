#!/usr/bin/env bash
# Stops the T3 server CodeLaunch started, and the Cloudflare tunnel it started
# with it. Idempotent: a re-run is a clean no-op.
#
# Only processes recorded as CodeLaunch-owned are signalled. A T3 Desktop app or
# a server you started yourself is reported and left running.
#
# T3 account authentication and the T3 Connect link are never touched - stopping
# the server is not a reason to unlink this environment.
set -euo pipefail
umask 077
cd "$(dirname "$0")"
. ./scripts/env.sh

usage() {
  cat <<'EOF'
Usage: ./t3-stop.sh
       ./t3-stop.sh -h|--help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- a. the server we own --------------------------------------------------
# Shutdown reads the recorded mode rather than .env, so a stack started in one
# mode still tears down correctly after the configuration moved on.
owned_pid=''
owned_children=''
run_mode=''
if owned_pid=$(codelaunch_t3_owned_pid); then
  run_mode=$CODELAUNCH_T3_MODE
  owned_children=$(codelaunch_t3_server_child_pids "$owned_pid" | tr '\n' ' ')
  echo "stopping CodeLaunch-owned T3 server (PID $owned_pid, mode $run_mode) ..."
  if codelaunch_t3_stop_pid "$owned_pid"; then
    if codelaunch_t3_clear_state; then
      echo "T3 server stopped"
    else
      echo "WARNING: T3 server stopped, but its ownership record could not be cleared"
    fi
  else
    echo "WARNING: T3 server is still running after SIGKILL (PID $owned_pid); ownership retained for a later retry"
  fi
else
  owned_status=$?
  if [ "$owned_status" -eq 2 ]; then
    echo "WARNING: invalid T3 ownership record; refusing to signal anything."
    echo "  Inspect and remove $HOME/.codelaunch/run/t3-serve.pid, then rerun ./t3-stop.sh."
  else
    # codelaunch_t3_owned_pid drops a record it can prove is dead or recycled.
    echo "no CodeLaunch-owned T3 server running"
  fi
fi

# --- b. the tunnel we started ----------------------------------------------
tunnel_name=''
if codelaunch_t3_read_tunnel_state; then
  tunnel_name=$CODELAUNCH_T3_TUNNEL
else
  tunnel_status=$?
  if [ "$tunnel_status" -eq 2 ]; then
    echo "WARNING: invalid tunnel ownership record; leaving cloudflared alone."
    echo "  Inspect and remove $HOME/.codelaunch/run/t3-tunnel, then rerun ./t3-stop.sh."
  fi
fi
if [ -n "$tunnel_name" ]; then
  tunnel_pids=$(codelaunch_tunnel_pids "$tunnel_name")
  if [ -n "$tunnel_pids" ]; then
    echo "stopping tunnel $tunnel_name ..."
    for p in $tunnel_pids; do kill "$p" 2>/dev/null || true; done
    for _ in $(seq 1 35); do
      tunnel_alive=0
      for p in $tunnel_pids; do
        if kill -0 "$p" 2>/dev/null; then tunnel_alive=1; break; fi
      done
      [ "$tunnel_alive" = 0 ] && break
      sleep 1
    done
    tunnel_pids=$(codelaunch_tunnel_pids "$tunnel_name")
    if [ -n "$tunnel_pids" ]; then
      echo "tunnel still up after grace - sending second signal"
      for p in $tunnel_pids; do kill "$p" 2>/dev/null || true; done
    fi
  fi
  if [ -n "$(codelaunch_tunnel_pids "$tunnel_name")" ]; then
    echo "WARNING: tunnel $tunnel_name is still running; ownership retained for a later retry"
  else
    codelaunch_t3_clear_tunnel_state || echo "WARNING: tunnel ownership record could not be cleared"
    echo "tunnel $tunnel_name stopped"
  fi
fi

# --- c. what was left alone ------------------------------------------------
# Unquoted on purpose - both are numeric PID lists that must word-split.
unowned=$(codelaunch_t3_unowned_pids $owned_pid $owned_children | tr '\n' ' ')
unowned=${unowned% }
if [ -n "$unowned" ]; then
  echo "headless T3 server(s) not started by CodeLaunch left running (PID $unowned)"
  echo "  Stop one yourself with: kill <pid>"
fi
echo "T3 sign-in and the T3 Connect link are untouched"
