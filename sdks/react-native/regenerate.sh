#!/bin/sh
set -eu
cd "$(dirname "$0")"
npm ci --ignore-scripts
npm run generate
