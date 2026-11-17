#!/bin/sh
set -eu

sdk=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$sdk/../.." && pwd)
version=7.27.0
sha256=db9c4b738727698748746144394cb7ee96512fe50166555baaeeca9311ee1dba
cache="${RELAY_TOOL_CACHE:-$sdk/build/tools}"
jar="$cache/openapi-generator-cli-$version.jar"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$cache"
if [ ! -f "$jar" ]; then
  curl -fsSL -o "$jar.part" "https://repo1.maven.org/maven2/org/openapitools/openapi-generator-cli/$version/openapi-generator-cli-$version.jar"
  mv "$jar.part" "$jar"
fi
echo "$sha256  $jar" | sha256sum -c -

npx --yes @redocly/cli@2.69.0 bundle "$root/contracts/openapi/subscriber.yaml" --output "$work/openapi.yaml"

java -jar "$jar" generate \
  --generator-name kotlin \
  --input-spec "$work/openapi.yaml" \
  --output "$work/out" \
  --package-name app.suiss.relay.api \
  --model-package app.suiss.relay.api.model \
  --global-property models,modelDocs=false,modelTests=false \
  --additional-properties serializationLibrary=gson,dateLibrary=string,enumPropertyNaming=UPPERCASE,sourceFolder=src/main/kotlin \
  --skip-validate-spec

target="$sdk/relay/src/generated/kotlin"
rm -rf "$target"
mkdir -p "$target"
cp -R "$work/out/src/main/kotlin/." "$target/"
