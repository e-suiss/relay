#!/bin/sh
set -eu
cd "$(dirname "$0")"
if [ ! -f node_modules/.package-lock.json ]; then
  npm ci --no-audit --no-fund
fi
npm run generate
