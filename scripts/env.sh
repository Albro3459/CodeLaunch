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
    T3_HOSTNAME|T3_PORT|T3_CHANNEL|T3_CHANNEL_SKIP_CHECK|TUNNEL_NAME|ACCESS_EMAIL|CLOUDFLARE_TEAM) return 0 ;;
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
      *) echo "$env_file:$line_number: expected KEY=value" >&2; return 1 ;;
    esac

    key=${line%%=*}
    raw_value=${line#*=}
    codelaunch_trim "$key"
    key=$CODELAUNCH_VALUE
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
    if codelaunch_requested_env "$key" "$@"; then
      printf -v "$key" '%s' "$value"
      export "$key"
    fi
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

codelaunch_prepare_runtime() {
  local root="$HOME/.codelaunch"
  CODELAUNCH_RUNTIME_DIR="$root/run"
  [ ! -L "$root" ] || { echo "REFUSING: runtime path is a symlink: $root" >&2; return 1; }
  [ ! -L "$CODELAUNCH_RUNTIME_DIR" ] || { echo "REFUSING: runtime path is a symlink: $CODELAUNCH_RUNTIME_DIR" >&2; return 1; }
  mkdir -p "$root" "$CODELAUNCH_RUNTIME_DIR"
  chmod 700 "$root" "$CODELAUNCH_RUNTIME_DIR"
  export CODELAUNCH_RUNTIME_DIR
}
