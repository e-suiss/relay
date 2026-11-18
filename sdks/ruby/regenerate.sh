#!/bin/sh
# X-53
set -eu

cd "$(dirname "$0")"
ruby codegen/generate.rb
