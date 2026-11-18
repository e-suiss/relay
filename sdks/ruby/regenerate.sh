#!/usr/bin/env bash
# X-53
set -euo pipefail

cd "$(dirname "$0")"
ruby codegen/generate.rb
