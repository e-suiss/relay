#!/bin/sh
# OP-98
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out="${1:-$here/dist}"
incidents="${2:-$here/incidents}"
generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$out"
find "$incidents" -type f -name '*.json' -exec cat {} + | jq -s . > "$out/incidents.json"
jq -r --arg mode html --arg generated "$generated" --slurpfile incidents "$out/incidents.json" -f "$here/render.jq" "$here/site.json" > "$out/index.html"
jq --arg mode json --arg generated "$generated" --slurpfile incidents "$out/incidents.json" -f "$here/render.jq" "$here/site.json" > "$out/status.json"
cp "$here/style.css" "$out/style.css"
rm "$out/incidents.json"
echo "status page built in $out"
