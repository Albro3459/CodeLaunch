#!/usr/bin/env bash
# Restart only the T3 backend after refreshing Claude or Codex CLI authentication.
#
#   ./t3-restart.sh              # same options as ./t3-start.sh
#   ./t3-restart.sh -d 5m        # pairing summary without the menu, 5m token
set -euo pipefail
cd "$(dirname "$0")"

./stop.sh t3 && ./t3-start.sh "$@"
