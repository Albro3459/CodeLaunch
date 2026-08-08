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

codelaunch_codex_web_gpt_app_path() {
  local app_path executable
  app_path=$(/usr/bin/osascript -e 'POSIX path of (path to application id "dev.codexwebgpt.launcher")' 2>/dev/null) || return 1
  app_path=${app_path%/}
  executable="$app_path/Contents/MacOS/Codex Web GPT"
  [ -d "$app_path" ] || return 1
  [ -x "$executable" ] || return 1
  printf '%s\n' "$app_path"
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
  kill -0 "$pid" 2>/dev/null || return 2
  if codelaunch_codex_web_gpt_record_matches "$pid"; then
    printf '%s\n' "$pid"
    return 0
  fi
  return 2
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
