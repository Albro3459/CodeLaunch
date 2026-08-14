#!/usr/bin/env bash
# Restart only the T3 backend after refreshing Claude or Codex CLI authentication.
set -euo pipefail
cd "$(dirname "$0")"

./stop.sh t3 && ./t3-pair.sh --ensure-only
