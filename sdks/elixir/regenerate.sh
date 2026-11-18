#!/usr/bin/env sh
set -eu
if ! command -v mix > /dev/null 2>&1; then
  echo "mix is not installed, skipping sdks/elixir"
  exit 0
fi
cd "$(dirname "$0")"
mix deps.get
mix esuiss_relay.gen
mix format
