#!/usr/bin/env sh
set -eu
if ! command -v gradle > /dev/null 2>&1; then
  echo "gradle is not installed, skipping sdks/java"
  exit 0
fi
cd "$(dirname "$0")"
gradle --no-daemon test --tests app.suiss.relay.LiveSmokeTest
