#!/bin/sh
set -eu

sdk=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$sdk/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

npx --yes @redocly/cli@2.69.0 bundle "$root/contracts/openapi/subscriber.yaml" --output "$work/openapi.yaml"

resolved=""
if [ -f "$sdk/Generator/Package.resolved" ]; then
  resolved="--force-resolved-versions"
fi

swift run $resolved --package-path "$sdk/Generator" -c release swift-openapi-generator generate \
  --config "$sdk/Generator/openapi-generator-config.yaml" \
  --output-directory "$sdk/Sources/EsuissRelayAPI" \
  "$work/openapi.yaml"
