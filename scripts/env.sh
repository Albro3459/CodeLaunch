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
    T3_HOSTNAME|T3_PORT|T3_BIND|T3_CHANNEL|T3_CHANNEL_SKIP_CHECK|T3_PUBLISH_ACTIVITY|TUNNEL_NAME|ACCESS_EMAIL|CLOUDFLARE_TEAM) return 0 ;;
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
