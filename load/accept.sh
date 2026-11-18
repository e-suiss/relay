#!/bin/sh
# OP-93
# T-84
set -eu

rate="${1:-50}"
seconds="${2:-30}"
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

"$here/install-vegeta.sh"
mix relay.dev.load_targets https://localhost "$rate" "$seconds" "$work/accept.txt" \
  --connect "${LOAD_BASE_URL:-http://localhost:4000}" \
  --header "X-Forwarded-Proto: https" --header "X-Forwarded-Host: localhost"
"$here/run.sh" "$work/accept.txt" "$rate/1s" "${seconds}s"
