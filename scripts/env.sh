#!/usr/bin/env bash
# Shared environment and private runtime helpers. Source this file; do not execute it.

CODELAUNCH_VALUE=''

codelaunch_trim() {
  CODELAUNCH_VALUE=$1
  CODELAUNCH_VALUE="${CODELAUNCH_VALUE#${CODELAUNCH_VALUE%%[!$' \t\r\n']*}}"
  CODELAUNCH_VALUE="${CODELAUNCH_VALUE%${CODELAUNCH_VALUE##*[!$' \t\r\n']}}"
}

codelaunch_allowed_env() {
  case "$1" in
    CLAUDEX_ENABLED|T3_ENABLED|T3_MODE|T3_CUSTOM_ACCESS) return 0 ;;
    T3_HOSTNAME|T3_PORT|T3_BIND|T3_CHANNEL|T3_CHANNEL_SKIP_CHECK|T3_PUBLISH_ACTIVITY|CODEX_WEB_GPT_MANAGED|TUNNEL_NAME|ACCESS_EMAIL|CLOUDFLARE_TEAM) return 0 ;;
    *) return 1 ;;
  esac
}

codelaunch_requested_env() {
  local key=$1 requested
  shift
  [ "$#" -eq 0 ] && return 0
  for requested in "$@"; do
    [ "$requested" = "$key" ] && return 0
  done
  return 1
}

codelaunch_parse_value() {
  local value=$1 first last inner char next i
  codelaunch_trim "$value"
  value=$CODELAUNCH_VALUE
  [ -z "$value" ] && { CODELAUNCH_VALUE=''; return 0; }
  first=${value:0:1}
  last=${value: -1}
  if [ "$first" = "'" ] || [ "$first" = '"' ]; then
    [ "$last" = "$first" ] || return 1
    inner=${value:1:${#value}-2}
    value=''
    i=0
    while [ "$i" -lt "${#inner}" ]; do
      char=${inner:$i:1}
      if [ "$first" = '"' ] && [ "$char" = $'\\' ]; then
        i=$((i + 1))
        [ "$i" -lt "${#inner}" ] || return 1
        next=${inner:$i:1}
        [ "$next" = $'\\' ] || [ "$next" = '"' ] || return 1
        value=$value$next
      else
        [ "$char" != "$first" ] || return 1
        case "$char" in
          [A-Za-z0-9._:@/+,%-]|' ') value=$value$char ;;
          *) return 1 ;;
        esac
      fi
      i=$((i + 1))
    done
  else
    case "$value" in
      *[!A-Za-z0-9._:@/+,%-]*) return 1 ;;
    esac
  fi
  CODELAUNCH_VALUE=$value
}

codelaunch_load_env() {
  local optional=0 env_file=.env
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --optional) optional=1; shift ;;
      --file)
        [ "$#" -ge 2 ] || { echo "codelaunch_load_env: --file requires a path" >&2; return 2; }
        env_file=$2
        shift 2
        ;;
      --) shift; break ;;
      -*) echo "codelaunch_load_env: unknown option '$1'" >&2; return 2 ;;
      *) break ;;
    esac
  done

  local requested
  for requested in "$@"; do
    codelaunch_allowed_env "$requested" || {
      echo "codelaunch_load_env: unsupported variable '$requested'" >&2
      return 2
    }
  done

  if [ ! -f "$env_file" ]; then
    [ "$optional" = 1 ] && return 0
    echo "$env_file missing. Run: cp .env.example .env and fill it in." >&2
    return 1
  fi

  local line line_number=0 key raw_value value
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    case "$line" in *$'\r') line=${line%$'\r'} ;; esac
    codelaunch_trim "$line"
    line=$CODELAUNCH_VALUE
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac

    case "$line" in
      export[[:space:]]*) line=${line#export}; codelaunch_trim "$line"; line=$CODELAUNCH_VALUE ;;
    esac
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac

    key=${line%%=*}
    raw_value=${line#*=}
    codelaunch_trim "$key"
    key=$CODELAUNCH_VALUE
    # Only the requested keys are parsed; anything else in .env is ignored.
    codelaunch_requested_env "$key" "$@" || continue
    if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      echo "$env_file:$line_number: invalid variable name '$key'" >&2
      return 1
    fi
    codelaunch_allowed_env "$key" || {
      echo "$env_file:$line_number: unsupported variable '$key'" >&2
      return 1
    }
    codelaunch_parse_value "$raw_value" || {
      echo "$env_file:$line_number: unsupported value for '$key'" >&2
      return 1
    }
    value=$CODELAUNCH_VALUE
    printf -v "$key" '%s' "$value"
    export "$key"
  done < "$env_file"
}

codelaunch_require_env() {
  local key
  for key in "$@"; do
    [ -n "${!key:-}" ] || { echo "set $key in .env" >&2; return 1; }
  done
}

# Best-effort GUI alert for startup preflight warnings. The terminal warning is
# always emitted by the caller, so headless starts do not depend on a GUI or on
# AppleScript being available.
codelaunch_macos_alert() {
  local title=${1:-CodeLaunch} message=${2:-}
  [ -x /usr/bin/osascript ] || return 0
  /usr/bin/osascript - "$title" "$message" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
  set alertTitle to item 1 of argv
  set alertMessage to item 2 of argv
  display alert alertTitle message alertMessage as warning
end run
APPLESCRIPT
}

# Print the PIDs of the actual ChatGPT desktop app process. Matching the
# executable inside ChatGPT.app avoids confusing unrelated command-line tools
# or the app's helper processes with the desktop app itself.
codelaunch_chatgpt_desktop_pids() {
  local line pid ppid command
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    [ -n "$line" ] || continue
    pid=${line%%[[:space:]]*}
    line=${line#"$pid"}
    line=${line#"${line%%[![:space:]]*}"}
    ppid=${line%%[[:space:]]*}
    command=${line#"$ppid"}
    command=${command#"${command%%[![:space:]]*}"}
    if [[ "$command" =~ /ChatGPT\.app/Contents/MacOS/ChatGPT([[:space:]]|$) ]]; then
      printf '%s\n' "$pid"
    fi
  done < <(ps -ax -o pid=,ppid=,command= 2>/dev/null || true)
}

# Print PID/command rows for Codex processes owned by, or embedded in, the
# ChatGPT desktop app. codex-code-mode-host is included because it can remain
# after the app's visible process exits and still conflict with T3's server.
codelaunch_chatgpt_codex_conflict_processes() {
  local line pid ppid command
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    [ -n "$line" ] || continue
    pid=${line%%[[:space:]]*}
    line=${line#"$pid"}
    line=${line#"${line%%[![:space:]]*}"}
    ppid=${line%%[[:space:]]*}
    command=${line#"$ppid"}
    command=${command#"${command%%[![:space:]]*}"}
    if [[ "$command" == *ChatGPT.app/*/codex* || "$command" == *codex-code-mode-host* ]]; then
      printf '%s %s %s\n' "$pid" "$ppid" "$command"
    fi
  done < <(ps -ax -o pid=,ppid=,command= 2>/dev/null || true)
}

# Check which side owns the Codex app-server before any services are started.
# This never starts or quits ChatGPT; callers can act on the printed command.
codelaunch_codex_desktop_preflight() {
  local managed=${1:-0} chatgpt_pids conflict_processes
  chatgpt_pids=$(codelaunch_chatgpt_desktop_pids)

  if [ "$managed" = 1 ]; then
    if [ -z "$chatgpt_pids" ]; then
      echo "WARNING: ChatGPT Desktop is not running."
      echo "  Codex Web GPT can start headless, but its web-backed Codex models will not work without the ChatGPT app; CodeLaunch did not start it."
      codelaunch_macos_alert "ChatGPT Desktop is not running" "Codex Web GPT models require the ChatGPT Desktop app to be running. CodeLaunch did not start the app."
      return 1
    fi
    return 0
  fi

  conflict_processes=$(codelaunch_chatgpt_codex_conflict_processes)
  if [ -n "$chatgpt_pids" ] || [ -n "$conflict_processes" ]; then
    echo "WARNING: ChatGPT Desktop or its Codex processes are running and conflict with T3's Codex app-server."
    echo "  With CODEX_WEB_GPT_MANAGED=0, T3 must own the Codex app-server; models and tool calls can fail until the conflicting processes are gone."
    [ -z "$conflict_processes" ] || {
      echo "  conflicting process(es):"
      while IFS= read -r line; do echo "    $line"; done <<< "$conflict_processes"
    }
    echo "  Quit ChatGPT manually, then rerun ./start.sh:"
    echo "    osascript -e 'tell application \"ChatGPT\" to quit'"
    codelaunch_macos_alert "ChatGPT must be quit" "Quit ChatGPT before starting CodeLaunch so T3 can own the Codex app-server. Run: osascript -e 'tell application \"ChatGPT\" to quit'"
    return 1
  fi
}

codelaunch_private_file() {
  [ ! -e "$1" ] || chmod 600 "$1"
}

codelaunch_private_tree() {
  local root=$1 path
  mkdir -p "$root"
  while IFS= read -r -d '' path; do chmod 700 "$path"; done < <(find "$root" -type d -print0)
  while IFS= read -r -d '' path; do chmod 600 "$path"; done < <(find "$root" -type f -print0)
}

codelaunch_reset_private_log() {
  [ ! -L "$1" ] || { echo "REFUSING: log path is a symlink: $1" >&2; return 1; }
  : > "$1"
  chmod 600 "$1"
}

# Current non-loopback, non-link-local IPv4 addresses.
codelaunch_local_ipv4() {
  /sbin/ifconfig 2>/dev/null \
    | awk '$1 == "inet" && $2 != "127.0.0.1" { print $2 }' \
    | grep -vE '^169\.254\.' \
    | sort -u
}

# Emits `label|address` rows for active VPN interfaces, in stable order.
codelaunch_vpn_ipv4() {
  local iface address
  /sbin/ifconfig -l 2>/dev/null | tr ' ' '\n' | awk '/^utun[0-9]+$/ { print }' | sort | while IFS= read -r iface; do
    [ -n "$iface" ] || continue
    /sbin/ifconfig "$iface" 2>/dev/null \
      | awk '$1 == "inet" { print $2 }' \
      | while IFS= read -r address; do
          case "$address" in
            ''|127.*|169.254.*) continue ;;
            *.*.*.*) printf 'VPN|%s\n' "$address" ;;
          esac
        done
  done | sort -t '|' -k2,2 -k1,1 -u
}

# Emits one `label|address` row for the active Wi-Fi interface.
codelaunch_wifi_ipv4() {
  local port address
  [ -x /usr/sbin/networksetup ] || return 0
  [ -x /usr/sbin/ipconfig ] || return 0
  port=$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null \
    | awk '/^Hardware Port: (Wi-Fi|AirPort)$/ { wanted=1; next } /^Hardware Port:/ { wanted=0 } wanted && /^Device:/ { print $2; exit }')
  [ -n "$port" ] || return 0
  address=$(/usr/sbin/ipconfig getifaddr "$port" 2>/dev/null || true)
  case "$address" in
    ''|127.*|169.254.*) return 0 ;;
    *.*.*.*) printf 'Wi-Fi|%s\n' "$address" ;;
  esac
}

# Match only the named tunnel, not unrelated cloudflared connectors.
codelaunch_tunnel_pids() {
  local name=$1 pid args
  [ -n "$name" ] || return 0
  for pid in $(pgrep -f 'cloudflared tunnel run' 2>/dev/null); do
    args=$(ps -ww -p "$pid" -o args= 2>/dev/null) || continue
    case " $args " in *" $name "*) echo "$pid" ;; esac
  done
}

codelaunch_prepare_runtime() {
  local root="$HOME/.codelaunch"
  CODELAUNCH_RUNTIME_DIR="$root/run"
  [ ! -L "$root" ] || { echo "REFUSING: runtime path is a symlink: $root" >&2; return 1; }
  [ ! -L "$CODELAUNCH_RUNTIME_DIR" ] || { echo "REFUSING: runtime path is a symlink: $CODELAUNCH_RUNTIME_DIR" >&2; return 1; }
  mkdir -p "$root" "$CODELAUNCH_RUNTIME_DIR"
  chmod 700 "$root" "$CODELAUNCH_RUNTIME_DIR"
  export CODELAUNCH_RUNTIME_DIR
}

# --- T3 lifecycle ----------------------------------------------------------
# Log lines the server prints on startup. The reconcile pair is the only signal
# that the stored T3 Connect credential still works - `connect status` reports
# "provisioned" off local files even after the relay refused the credential.
CODELAUNCH_T3_READY='T3 Code server is ready.'
CODELAUNCH_T3_RECONCILE_OK='T3 Connect desired link reconciled on startup'
CODELAUNCH_T3_RECONCILE_FAIL='Failed to reconcile T3 Connect desired link on startup'

# Reads the channel from CFBundleShortVersionString (e.g. 0.0.29-nightly.20260722.875 -> nightly) so a renamed .app still classifies correctly.
codelaunch_t3_app_channel() {
  local ver
  ver=$(defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null) || return 1
  [ -n "$ver" ] || return 1
  case "$ver" in
    *nightly*) echo "nightly" ;;
    *)         echo "latest" ;;
  esac
}

# Prefers the app that owns $1, when a port is given, since that's the backend
# the CLI will migrate against. Falls back to scanning installed bundles.
# Returns 2 when several are installed and none owns the port.
codelaunch_t3_desktop_app() {
  local port=${1:-} running_pid running_cmd found='' n=0 dir app
  if [ -n "$port" ]; then
    running_pid=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)
    if [ -n "$running_pid" ]; then
      running_cmd=$(ps -p "$running_pid" -o command= 2>/dev/null || true)
      # Strips at the first ".app/" to get the outermost bundle, since Electron helper bundles are nested and have no version string of their own.
      case "$running_cmd" in
        *.app/Contents/*) printf '%s\n' "${running_cmd%%.app/*}.app"; return 0 ;;
      esac
    fi
  fi
  for dir in /Applications "$HOME/Applications"; do
    for app in "$dir"/T3\ Code*.app; do
      [ -d "$app" ] || continue
      found=$app
      n=$((n + 1))
    done
  done
  [ "$n" -ne 0 ] || return 1
  [ "$n" -eq 1 ] || return 2
  printf '%s\n' "$found"
}

# T3_CHANNEL must match the installed desktop app, since both sides share the
# ~/.t3 store and a mismatched migration can break it.
codelaunch_t3_channel_guard() {
  local channel=$1 port=${2:-} app status app_channel
  if [ "${T3_CHANNEL_SKIP_CHECK:-0}" = 1 ]; then
    echo "WARNING: T3_CHANNEL_SKIP_CHECK=1 - channel match not verified"
    return 0
  fi
  if ! app=$(codelaunch_t3_desktop_app "$port"); then
    status=$?
    if [ "$status" -eq 2 ]; then
      echo "note: multiple T3 Code apps installed - cannot verify T3_CHANNEL against a specific one"
    else
      echo "no T3 desktop app found - using T3_CHANNEL=$channel for the headless backend"
    fi
    return 0
  fi
  if ! app_channel=$(codelaunch_t3_app_channel "$app"); then
    echo "note: could not read a version from $app - skipping channel check"
    return 0
  fi
  if [ "$app_channel" != "$channel" ]; then
    echo "REFUSING: T3_CHANNEL=$channel but the desktop app is '$app_channel'."
    echo "  app:  $app"
    echo "  Mismatched channels can corrupt the shared ~/.t3 store during migrations."
    echo "  Fix: set T3_CHANNEL=$app_channel in .env, or install the $channel cask."
    echo "  Override (not recommended): T3_CHANNEL_SKIP_CHECK=1 ./t3-start.sh"
    return 1
  fi
  echo "channel ok: T3_CHANNEL=$channel matches the desktop app"
}

# Prints ok, failed, or unknown for this boot's T3 Connect link reconcile.
codelaunch_t3_wait_reconcile() {
  local log=$1 timeout=${2:-45} _
  for _ in $(seq 1 "$timeout"); do
    if grep -qF "$CODELAUNCH_T3_RECONCILE_OK" "$log" 2>/dev/null; then echo ok; return 0; fi
    if grep -qF "$CODELAUNCH_T3_RECONCILE_FAIL" "$log" 2>/dev/null; then echo failed; return 0; fi
    sleep 1
  done
  echo unknown
}

codelaunch_t3_state_file() {
  local root="$HOME/.codelaunch"
  [ ! -L "$root" ] || return 2
  [ ! -L "$root/run" ] || return 2
  printf '%s/run/t3-serve.pid\n' "$root"
}

codelaunch_t3_start_identity() {
  local pid=$1 identity
  # Pin locale/timezone so the recorded identity compares stably across DST changes
  identity=$(LC_ALL=C TZ=UTC ps -p "$pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}') || return 1
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity"
}

codelaunch_t3_command() {
  local pid=$1 args
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  args=$(ps -ww -p "$pid" -o args= 2>/dev/null) || return 1
  codelaunch_trim "$args"
  [ -n "$CODELAUNCH_VALUE" ] || return 1
  printf '%s\n' "$CODELAUNCH_VALUE"
}

# `npx` stays alive as the server's supervisor, but the long-lived server is the
# node child it spawns. Resolve it before signalling, since it is reparented to
# launchd once the supervisor exits and can no longer be found by parent.
codelaunch_t3_server_child_pids() {
  local parent=$1 pid args
  case "$parent" in ''|*[!0-9]*) return 0 ;; esac
  for pid in $(pgrep -P "$parent" 2>/dev/null || true); do
    args=$(ps -ww -p "$pid" -o args= 2>/dev/null) || continue
    case "$args" in *"t3 serve"*) printf '%s\n' "$pid" ;; esac
  done
}

codelaunch_t3_read_state() {
  local file pid identity command mode extra
  CODELAUNCH_T3_PID=''
  CODELAUNCH_T3_START_IDENTITY=''
  CODELAUNCH_T3_COMMAND=''
  CODELAUNCH_T3_MODE=''
  file=$(codelaunch_t3_state_file) || return 2
  [ -e "$file" ] || return 1
  [ ! -L "$file" ] || return 2
  [ -f "$file" ] || return 2
  [ -s "$file" ] || return 1
  extra=''
  { IFS= read -r pid; IFS= read -r identity; IFS= read -r command; IFS= read -r mode; IFS= read -r extra; } < "$file" || true
  case "$pid" in ''|0|*[!0-9]*) return 2 ;; esac
  [ -n "$identity" ] && [ -n "$command" ] && [ -z "$extra" ] || return 2
  case "$mode" in connect|custom-direct|custom-full) ;; *) return 2 ;; esac
  CODELAUNCH_T3_PID=$pid
  CODELAUNCH_T3_START_IDENTITY=$identity
  CODELAUNCH_T3_COMMAND=$command
  CODELAUNCH_T3_MODE=$mode
}

codelaunch_t3_write_state() {
  local pid=$1 mode=$2 file identity command
  codelaunch_prepare_runtime || return 2
  file=$(codelaunch_t3_state_file) || return 2
  [ ! -L "$file" ] || { echo "REFUSING: T3 state path is a symlink: $file" >&2; return 1; }
  identity=$(codelaunch_t3_start_identity "$pid") || return 1
  command=$(codelaunch_t3_command "$pid") || return 1
  printf '%s\n%s\n%s\n%s\n' "$pid" "$identity" "$command" "$mode" > "$file"
  chmod 600 "$file"
}

codelaunch_t3_clear_state() {
  local file
  file=$(codelaunch_t3_state_file) || return 2
  [ ! -L "$file" ] || { echo "REFUSING: T3 state path is a symlink: $file" >&2; return 1; }
  [ ! -e "$file" ] || : > "$file"
  [ ! -e "$file" ] || chmod 600 "$file"
}

# True when $1 is still the exact server recorded in the state file.
codelaunch_t3_state_matches() {
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  codelaunch_t3_read_state || return 1
  [ "$CODELAUNCH_T3_PID" = "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ "$(codelaunch_t3_command "$pid" 2>/dev/null)" = "$CODELAUNCH_T3_COMMAND" ] || return 1
  [ "$(codelaunch_t3_start_identity "$pid" 2>/dev/null)" = "$CODELAUNCH_T3_START_IDENTITY" ]
}

# Prints the owned PID and leaves CODELAUNCH_T3_PID/CODELAUNCH_T3_MODE set, so
# call it directly - through $( ) the record stays in the subshell. Returns 1
# when nothing is owned, 2 when the record exists but cannot be trusted.
codelaunch_t3_owned_pid() {
  local pid rc
  codelaunch_t3_read_state
  rc=$?
  case "$rc" in
    1) return 1 ;;
    2) return 2 ;;
  esac
  pid=$CODELAUNCH_T3_PID
  if codelaunch_t3_state_matches "$pid"; then
    printf '%s\n' "$pid"
    return 0
  fi
  # Provably not the recorded server any more (dead or recycled PID), so the
  # record is stale rather than untrustworthy - drop it instead of wedging start.
  codelaunch_t3_clear_state || return 2
  return 1
}

# Headless T3 servers that CodeLaunch did not start, minus any PID passed in.
# Reported, never signalled.
codelaunch_t3_unowned_pids() {
  local excluded=" $* " pid args
  for pid in $(pgrep -f 't3 serve' 2>/dev/null || true); do
    case "$excluded" in *" $pid "*) continue ;; esac
    args=$(ps -ww -p "$pid" -o args= 2>/dev/null) || continue
    case "$args" in
      *.app/Contents/*) continue ;;
      *"t3 serve"*) printf '%s\n' "$pid" ;;
    esac
  done
}

# SIGTERM the supervisor and its server child, escalating once after a grace period.
codelaunch_t3_stop_pid() {
  local pid=$1 children child alive _
  children=$(codelaunch_t3_server_child_pids "$pid")
  kill "$pid" 2>/dev/null || true
  for child in $children; do kill "$child" 2>/dev/null || true; done
  for _ in $(seq 1 20); do
    alive=0
    if kill -0 "$pid" 2>/dev/null; then alive=1; fi
    for child in $children; do
      if kill -0 "$child" 2>/dev/null; then alive=1; fi
    done
    [ "$alive" = 0 ] && return 0
    sleep 1
  done
  kill -9 "$pid" 2>/dev/null || true
  for child in $children; do kill -9 "$child" 2>/dev/null || true; done
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then return 1; fi
  for child in $children; do
    if kill -0 "$child" 2>/dev/null; then return 1; fi
  done
  return 0
}

# Starts `t3 serve` fully detached from the calling shell, verifies the server
# child actually came up, and records ownership. Extra arguments go to the CLI.
# The T3 CLI's only background lifecycle is `t3 service install`, which registers
# a launchd agent that also starts at login - too much persistent state for a
# start/stop pair, so CodeLaunch supervises the process itself.
codelaunch_t3_serve_start() {
  local mode=$1 pkg=$2 log=$3
  shift 3
  local pid='' child='' ready=0 _
  codelaunch_reset_private_log "$log" || return 1
  nohup npx --yes "$pkg" serve "$@" </dev/null >"$log" 2>&1 &
  pid=$!
  for _ in $(seq 1 90); do
    if grep -qF "$CODELAUNCH_T3_READY" "$log" 2>/dev/null; then ready=1; break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if [ "$ready" != 1 ]; then
    echo "T3 server did not report ready; last log lines:" >&2
    tail -20 "$log" >&2
    codelaunch_t3_stop_pid "$pid" || true
    return 1
  fi
  child=$(codelaunch_t3_server_child_pids "$pid" | head -1)
  if [ -z "$child" ]; then
    echo "T3 server process could not be verified; last log lines:" >&2
    tail -20 "$log" >&2
    codelaunch_t3_stop_pid "$pid" || true
    return 1
  fi
  if ! codelaunch_t3_write_state "$pid" "$mode"; then
    echo "T3 server started, but CodeLaunch could not record ownership of PID $pid" >&2
    echo "  It will be left running on stop. Stop it with: kill $pid" >&2
    return 1
  fi
  printf '%s\n' "$pid"
}

codelaunch_t3_tunnel_state_file() {
  local root="$HOME/.codelaunch"
  [ ! -L "$root" ] || return 2
  [ ! -L "$root/run" ] || return 2
  printf '%s/run/t3-tunnel\n' "$root"
}

# Recorded so shutdown tears down the tunnel that was actually started, even if
# .env has since moved to another mode or another tunnel name.
codelaunch_t3_write_tunnel_state() {
  local name=$1 file
  codelaunch_prepare_runtime || return 2
  file=$(codelaunch_t3_tunnel_state_file) || return 2
  [ ! -L "$file" ] || { echo "REFUSING: T3 tunnel state path is a symlink: $file" >&2; return 1; }
  printf '%s\n' "$name" > "$file"
  chmod 600 "$file"
}

codelaunch_t3_read_tunnel_state() {
  local file name extra
  CODELAUNCH_T3_TUNNEL=''
  file=$(codelaunch_t3_tunnel_state_file) || return 2
  [ -e "$file" ] || return 1
  [ ! -L "$file" ] || return 2
  [ -f "$file" ] || return 2
  [ -s "$file" ] || return 1
  extra=''
  { IFS= read -r name; IFS= read -r extra; } < "$file" || true
  [ -n "$name" ] && [ -z "$extra" ] || return 2
  case "$name" in *[!A-Za-z0-9._-]*) return 2 ;; esac
  CODELAUNCH_T3_TUNNEL=$name
}

codelaunch_t3_clear_tunnel_state() {
  local file
  file=$(codelaunch_t3_tunnel_state_file) || return 2
  [ ! -L "$file" ] || { echo "REFUSING: T3 tunnel state path is a symlink: $file" >&2; return 1; }
  [ ! -e "$file" ] || : > "$file"
  [ ! -e "$file" ] || chmod 600 "$file"
}

codelaunch_codex_web_gpt_verify_app() {
  local app_path=${1:-}
  [ -n "$app_path" ] || return 1
  app_path=${app_path%/}
  [ -d "$app_path" ] || return 1
  [ -x "$app_path/Contents/MacOS/Codex Web GPT" ] || return 1
  [ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app_path/Contents/Info.plist" 2>/dev/null)" \
    = dev.codexwebgpt.launcher ] || return 1
  printf '%s\n' "$app_path"
}

# Launch Services' `path to application id` sends an AppleEvent to the target, so
# it stalls for a minute and then fails with -1712 when the launcher is installed
# but not running - which is the usual case at start. Check the locations
# install-launcher.sh writes to, fall back to Spotlight, and confirm the bundle
# identifier either way.
codelaunch_codex_web_gpt_app_path() {
  local candidate candidates=()
  [ -z "${CODEX_WEB_GPT_APPLICATIONS_DIR:-}" ] \
    || candidates+=("${CODEX_WEB_GPT_APPLICATIONS_DIR%/}/Codex Web GPT.app")
  candidates+=("/Applications/Codex Web GPT.app" "$HOME/Applications/Codex Web GPT.app")
  for candidate in "${candidates[@]}"; do
    codelaunch_codex_web_gpt_verify_app "$candidate" && return 0
  done
  command -v mdfind >/dev/null 2>&1 || return 1
  while IFS= read -r candidate; do
    codelaunch_codex_web_gpt_verify_app "$candidate" && return 0
  done < <(mdfind "kMDItemCFBundleIdentifier == 'dev.codexwebgpt.launcher'" 2>/dev/null)
  return 1
}

codelaunch_codex_web_gpt_home() {
  local home=${CODEX_CHATGPT_WEB_HOME:-$HOME/.codex-chatgpt-web}
  home=${home%/}
  [ -d "$home" ] || return 1
  printf '%s\n' "$home"
}

# The macOS installer ships only the app bundle, so the CLI exists only in the
# private runtime directory the launcher provisions per release. config.json
# names the live release, which is what keeps this correct across updates -
# older version directories are left on disk and must not be picked up.
codelaunch_codex_web_gpt_runtime_cli() {
  local home version arch cli
  command -v jq >/dev/null 2>&1 || return 1
  home=$(codelaunch_codex_web_gpt_home) || return 1
  [ -f "$home/config.json" ] || return 1
  version=$(jq -re '.releaseVersion // empty' "$home/config.json" 2>/dev/null) || return 1
  case "$version" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64) arch=x64 ;;
    *) return 1 ;;
  esac
  cli="$home/versions/$version-darwin-$arch/bin/codex-chatgpt-web"
  [ ! -L "$cli" ] || return 1
  [ -x "$cli" ] || return 1
  printf '%s\n' "$cli"
}

codelaunch_codex_web_gpt_cli() {
  local cli
  cli=$(command -v codex-chatgpt-web 2>/dev/null || true)
  if [ -n "$cli" ] && [ -x "$cli" ]; then
    printf '%s\n' "$cli"
    return 0
  fi
  codelaunch_codex_web_gpt_runtime_cli
}

codelaunch_codex_web_gpt_read_route_status() {
  local cli=$1 output
  CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL=''
  CODELAUNCH_CODEX_WEB_GPT_ROUTE_INSTALLED=''
  CODELAUNCH_CODEX_WEB_GPT_ROUTE_ACTIVE=''
  CODELAUNCH_CODEX_WEB_GPT_ROUTE_URL=''
  CODELAUNCH_CODEX_WEB_GPT_ROUTE_ERRORS=''
  command -v jq >/dev/null 2>&1 || {
    CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL='jq is required to validate Codex Web GPT route status'
    return 1
  }
  if ! output=$("$cli" route status 2>&1); then
    CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL=$output
    return 1
  fi
  if ! printf '%s' "$output" | jq -e '
    type == "object" and
    (.installed | type == "boolean") and
    (.active | type == "boolean") and
    (.errors | type == "array") and
    all(.errors[]; type == "string") and
    ((has("routeUrl") | not) or (.routeUrl | type == "string"))
  ' >/dev/null 2>&1; then
    CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL='route status returned invalid or incomplete JSON'
    return 1
  fi
  CODELAUNCH_CODEX_WEB_GPT_ROUTE_INSTALLED=$(printf '%s' "$output" | jq -r '.installed')
  CODELAUNCH_CODEX_WEB_GPT_ROUTE_ACTIVE=$(printf '%s' "$output" | jq -r '.active')
  CODELAUNCH_CODEX_WEB_GPT_ROUTE_URL=$(printf '%s' "$output" | jq -r '.routeUrl // empty')
  CODELAUNCH_CODEX_WEB_GPT_ROUTE_ERRORS=$(printf '%s' "$output" | jq -r '.errors | join("; ")')
}

codelaunch_codex_web_gpt_set_route() {
  local cli=$1 action=$2 output
  CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL=''
  case "$action" in connect|disconnect) ;; *) return 2 ;; esac
  if ! output=$("$cli" route "$action" 2>&1); then
    CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL=$output
    return 1
  fi
  if ! printf '%s' "$output" | jq -e 'type == "object" and (.active | type == "boolean")' >/dev/null 2>&1; then
    CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL="route $action returned invalid or incomplete JSON"
    return 1
  fi
}

codelaunch_codex_web_gpt_health_url() {
  local route_url=$1 port port_number
  if [[ "$route_url" =~ ^http://127\.0\.0\.1:([0-9]{1,5})/v1/?$ ]]; then
    port=${BASH_REMATCH[1]}
    port_number=$((10#$port))
    [ "$port_number" -ge 1 ] && [ "$port_number" -le 65535 ] || return 1
    printf 'http://127.0.0.1:%s/healthz\n' "$port_number"
    return 0
  fi
  return 1
}

codelaunch_codex_web_gpt_health_reachable() {
  local health_url=$1 body
  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  body=$(curl --connect-timeout 1 --max-time 2 -fsS "$health_url" 2>/dev/null) || return 1
  printf '%s' "$body" | jq -e '.service == "codex-chatgpt-web" and .status == "ok"' >/dev/null 2>&1
}

codelaunch_codex_web_gpt_health_ok() {
  local health_url=$1 body
  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  body=$(curl --connect-timeout 1 --max-time 2 -fsS "$health_url" 2>/dev/null) || return 1
  printf '%s' "$body" | jq -e '
    .service == "codex-chatgpt-web" and
    .status == "ok" and
    .accepting_turns == true
  ' >/dev/null 2>&1
}

codelaunch_codex_web_gpt_wait_health() {
  local health_url=$1 attempts=${2:-60}
  for _ in $(seq 1 "$attempts"); do
    codelaunch_codex_web_gpt_health_ok "$health_url" && return 0
    sleep 1
  done
  return 1
}

codelaunch_codex_web_gpt_doctor_ok() {
  local cli=$1 output
  CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL=''
  if ! output=$("$cli" doctor --json 2>&1); then
    CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL=$output
    return 1
  fi
  if ! printf '%s' "$output" | jq -e '
    type == "object" and
    (.ok | type == "boolean") and
    (.checks | type == "array") and
    .ok == true
  ' >/dev/null 2>&1; then
    CODELAUNCH_CODEX_WEB_GPT_STATUS_DETAIL='doctor reported an unhealthy or invalid runtime'
    return 1
  fi
}

codelaunch_codex_web_gpt_exact_command() {
  local pid=$1 executable=$2 args
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  args=$(ps -ww -p "$pid" -o args= 2>/dev/null) || return 1
  codelaunch_trim "$args"
  args=$CODELAUNCH_VALUE
  case "$args" in
    "$executable"|"$executable --hidden"|"$executable -psn_"*) return 0 ;;
    *) return 1 ;;
  esac
}

codelaunch_codex_web_gpt_pids() {
  local app_path=$1 executable line pid args
  executable="$app_path/Contents/MacOS/Codex Web GPT"
  while IFS= read -r line; do
    codelaunch_trim "$line"
    line=$CODELAUNCH_VALUE
    case "$line" in *' '*) ;; *) continue ;; esac
    pid=${line%% *}
    args=${line#* }
    case "$args" in
      "$executable"|"$executable --hidden"|"$executable -psn_"*) printf '%s\n' "$pid" ;;
    esac
  done < <(ps -ax -o pid=,args= 2>/dev/null)
}

codelaunch_codex_web_gpt_running_pid() {
  local app_path=$1 pids
  pids=$(codelaunch_codex_web_gpt_pids "$app_path")
  set -- $pids
  case "$#" in
    0) return 1 ;;
    1) printf '%s\n' "$1" ;;
    *) return 2 ;;
  esac
}

codelaunch_codex_web_gpt_start_identity() {
  local pid=$1 identity
  identity=$(LC_ALL=C TZ=UTC ps -p "$pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}') || return 1
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity"
}

codelaunch_codex_web_gpt_pid_file() {
  local root="$HOME/.codelaunch"
  [ ! -L "$root" ] || return 2
  [ ! -L "$root/run" ] || return 2
  printf '%s/codex-web-gpt.pid\n' "$root/run"
}

codelaunch_codex_web_gpt_record_pid() {
  local file record pid identity executable
  CODELAUNCH_CODEX_WEB_GPT_PID=''
  CODELAUNCH_CODEX_WEB_GPT_START_IDENTITY=''
  CODELAUNCH_CODEX_WEB_GPT_EXECUTABLE=''
  file=$(codelaunch_codex_web_gpt_pid_file) || return 2
  [ -e "$file" ] || return 1
  [ ! -L "$file" ] || return 2
  [ -f "$file" ] || return 2
  [ -s "$file" ] || return 1
  record=$(awk 'NR == 1 { pid = $0; next } NR == 2 { identity = $0; next } NR == 3 { executable = $0; next } { bad = 1 } END { if (bad || pid !~ /^[0-9]+$/ || pid == 0 || identity == "" || executable == "") exit 1; print pid; print identity; print executable }' "$file") || return 2
  pid=${record%%$'\n'*}
  record=${record#*$'\n'}
  identity=${record%%$'\n'*}
  executable=${record#*$'\n'}
  case "$executable" in
    /*/Codex\ Web\ GPT.app/Contents/MacOS/Codex\ Web\ GPT) ;;
    *) return 2 ;;
  esac
  printf -v CODELAUNCH_CODEX_WEB_GPT_PID '%s' "$pid"
  printf -v CODELAUNCH_CODEX_WEB_GPT_START_IDENTITY '%s' "$identity"
  printf -v CODELAUNCH_CODEX_WEB_GPT_EXECUTABLE '%s' "$executable"
}

codelaunch_codex_web_gpt_clear_record() {
  local file
  file=$(codelaunch_codex_web_gpt_pid_file) || return 2
  [ ! -L "$file" ] || { echo "REFUSING: Codex Web GPT PID path is a symlink: $file" >&2; return 1; }
  [ ! -e "$file" ] || : > "$file"
  [ ! -e "$file" ] || chmod 600 "$file"
}

codelaunch_codex_web_gpt_record_matches() {
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  codelaunch_codex_web_gpt_record_pid || return 1
  [ "$CODELAUNCH_CODEX_WEB_GPT_PID" = "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  codelaunch_codex_web_gpt_exact_command "$pid" "$CODELAUNCH_CODEX_WEB_GPT_EXECUTABLE" || return 1
  [ "$(codelaunch_codex_web_gpt_start_identity "$pid")" = "$CODELAUNCH_CODEX_WEB_GPT_START_IDENTITY" ]
}

codelaunch_codex_web_gpt_owned_pid() {
  local pid rc
  codelaunch_codex_web_gpt_record_pid
  rc=$?
  case "$rc" in
    1) return 1 ;;
    2) return 2 ;;
  esac
  pid=$CODELAUNCH_CODEX_WEB_GPT_PID
  if codelaunch_codex_web_gpt_record_matches "$pid"; then
    printf '%s\n' "$pid"
    return 0
  fi
  # Provably not the recorded launcher any more (dead or recycled PID), so the
  # record is stale rather than untrustworthy - drop it instead of wedging start.
  codelaunch_codex_web_gpt_clear_record || return 2
  return 1
}

codelaunch_codex_web_gpt_write_pid() {
  local pid=$1 executable=$2 file identity
  codelaunch_prepare_runtime || return 2
  file=$(codelaunch_codex_web_gpt_pid_file) || return 2
  [ ! -L "$file" ] || { echo "REFUSING: Codex Web GPT PID path is a symlink: $file" >&2; return 1; }
  codelaunch_codex_web_gpt_exact_command "$pid" "$executable" || return 1
  identity=$(codelaunch_codex_web_gpt_start_identity "$pid") || return 1
  printf '%s\n%s\n%s\n' "$pid" "$identity" "$executable" > "$file"
  chmod 600 "$file"
}

codelaunch_caffeinate_pid_file() {
  local root="$HOME/.codelaunch"
  [ ! -L "$root" ] || return 2
  [ ! -L "$root/run" ] || return 2
  printf '%s/caffeinate.pid\n' "$root/run"
}

codelaunch_caffeinate_record_pid() {
  local file record pid identity
  file=$(codelaunch_caffeinate_pid_file) || return 2
  [ -e "$file" ] || return 1
  [ ! -L "$file" ] || return 2
  [ -f "$file" ] || return 2
  [ -s "$file" ] || return 1
  record=$(awk 'NR == 1 { pid = $0; next } NR == 2 { identity = $0; next } { bad = 1 } END { if (bad || pid !~ /^[0-9]+$/ || pid == 0 || identity == "") exit 1; print pid; print identity }' "$file") || return 2
  pid=${record%%$'\n'*}
  identity=${record#*$'\n'}
  printf -v CODELAUNCH_CAFFEINATE_PID '%s' "$pid"
  printf -v CODELAUNCH_CAFFEINATE_START_IDENTITY '%s' "$identity"
  return 0
}

codelaunch_caffeinate_clear_record() {
  local file
  file=$(codelaunch_caffeinate_pid_file) || return 2
  [ ! -L "$file" ] || { echo "REFUSING: caffeinate PID path is a symlink: $file" >&2; return 1; }
  [ ! -e "$file" ] || : > "$file"
  [ ! -e "$file" ] || chmod 600 "$file"
}

codelaunch_caffeinate_start_identity() {
  local pid=$1 identity
  # Pin locale/timezone so the recorded identity compares stably across DST changes
  identity=$(LC_ALL=C TZ=UTC ps -p "$pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}') || return 1
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity"
}

codelaunch_caffeinate_exact_command() {
  local pid=$1 args
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  args=$(ps -ww -p "$pid" -o args= 2>/dev/null) || return 1
  codelaunch_trim "$args"
  args=$CODELAUNCH_VALUE
  case "$args" in
    'caffeinate -dims'|/*/caffeinate\ -dims) return 0 ;;
    *) return 1 ;;
  esac
}

# True when $1 is still the exact caffeinate recorded in the PID file.
# Re-reads the record each call so it can be used again after a signal, when the PID may have been recycled.
codelaunch_caffeinate_record_matches() {
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  codelaunch_caffeinate_record_pid || return 1
  [ "$CODELAUNCH_CAFFEINATE_PID" = "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  codelaunch_caffeinate_exact_command "$pid" || return 1
  [ "$(codelaunch_caffeinate_start_identity "$pid")" = "$CODELAUNCH_CAFFEINATE_START_IDENTITY" ]
}

codelaunch_caffeinate_owned_pid() {
  local pid rc
  codelaunch_caffeinate_record_pid
  rc=$?
  case "$rc" in
    1) return 1 ;;
    2) return 2 ;;
  esac
  pid=$CODELAUNCH_CAFFEINATE_PID
  if codelaunch_caffeinate_record_matches "$pid"; then
    printf '%s\n' "$pid"
    return 0
  fi
  codelaunch_caffeinate_clear_record || return 2
  return 1
}

codelaunch_caffeinate_exact_pids() {
  local pid
  for pid in $(pgrep -x caffeinate 2>/dev/null || true); do
    codelaunch_caffeinate_exact_command "$pid" && printf '%s\n' "$pid"
  done
}

codelaunch_caffeinate_write_pid() {
  local pid=$1 file identity
  file=$(codelaunch_caffeinate_pid_file) || return 2
  [ ! -L "$file" ] || { echo "REFUSING: caffeinate PID path is a symlink: $file" >&2; return 1; }
  identity=$(codelaunch_caffeinate_start_identity "$pid") || return 1
  printf '%s\n%s\n' "$pid" "$identity" > "$file"
  chmod 600 "$file"
}
