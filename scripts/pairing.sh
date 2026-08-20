#!/usr/bin/env bash
# Shared pairing presentation helper. Source this file; do not execute it.

codelaunch_pairing_present() {
  local credential=$1 expires_at=$2 pair_url=$3 port=$4 bind=$5 detached=${6:-0} primary=${7:-Tunnel}
  local -a labels urls
  local row label address choice selected i

  labels=("$primary")
  urls=("$pair_url")
  if [ "$bind" = all ]; then
    while IFS='|' read -r label address; do
      [ -n "$address" ] || continue
      labels+=("$label")
      urls+=("http://$address:$port/pair#token=$credential")
    done < <(codelaunch_vpn_ipv4)
    while IFS='|' read -r label address; do
      [ -n "$address" ] || continue
      labels+=("$label")
      urls+=("http://$address:$port/pair#token=$credential")
    done < <(codelaunch_wifi_ipv4)
  fi

  if [ ! -t 0 ] || [ ! -t 1 ]; then detached=1; fi
  printf '\n============================================================\n'
  printf 'T3 PAIRING\n'
  printf '============================================================\n'
  printf 'CODE:       %s\n' "$credential"
  printf 'EXPIRES:    %s\n\n' "$expires_at"
  printf 'PAIR URLS\n'
  for i in "${!urls[@]}"; do
    printf '  %d. %-34s %s\n' "$((i + 1))" "${labels[$i]}" "${urls[$i]}"
  done
  if [ "$bind" = all ] && [ "${#urls[@]}" -eq 1 ]; then
    printf '  (no active VPN or Wi-Fi address found)\n'
  fi
  printf '\nWARNING: This is a one-time secret. Treat the code and URL like a password.\n'
  if [ "$detached" = 1 ]; then return 0; fi

  while :; do
    printf '\n[c] show QR  [q] quit pairing helper\n> '
    if ! IFS= read -r -n 1 choice; then
      printf '\n'
      return 0
    fi
    printf '\n'
    case "$choice" in
      q|Q) return 0 ;;
      c|C)
        printf 'URL number: '
        IFS= read -r choice || return 0
        case "$choice" in
          ''|*[!0-9]*) printf 'Invalid URL number.\n'; continue ;;
        esac
        if [ "${#choice}" -gt 9 ]; then
          printf 'Invalid URL number.\n'
          continue
        fi
        # 10# forces base-10 so leading zeros are not read as octal
        i=$((10#$choice - 1))
        if [ "$i" -lt 0 ] || [ "$i" -ge "${#urls[@]}" ]; then
          printf 'Invalid URL number.\n'
          continue
        fi
        selected=${urls[$i]}
        printf '\nCODE: %s\n' "$credential"
        if command -v qrencode >/dev/null 2>&1; then
          if ! printf '%s' "$selected" | qrencode -t ANSIUTF8 -o -; then
            printf '(QR rendering failed; use URL %s.)\n' "$selected"
          fi
        else
          printf '(qrencode not installed; use URL %s.)\n' "$selected"
        fi
        ;;
      *) printf 'Invalid choice.\n' ;;
    esac
  done
}
