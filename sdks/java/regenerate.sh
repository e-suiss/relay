#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
gradle --no-daemon generate spotlessApply
