#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
mix deps.get
mix esuiss_relay.gen
mix format
