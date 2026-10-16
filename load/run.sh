#!/bin/sh
# T-84
# F-23
set -eu

targets="$1"
rate="${2:-100/1s}"
duration="${3:-30s}"
base="${LOAD_BASE_URL:-http://localhost:4000}"
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/output/$(date -u +%Y%m%dT%H%M%SZ)-$(basename "$targets" .txt)"

"$here/install-vegeta.sh"
mkdir -p "$out"

{
  echo "commit: $(git -C "$here" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host: $(uname -srm)"
  echo "cores: $(getconf _NPROCESSORS_ONLN)"
  echo "target: $base"
  echo "rate: $rate"
  echo "duration: $duration"
  echo "model: open loop, constant arrival rate; latency measured from the scheduled start"
  echo "label: awaiting reproduction"
} > "$out/environment.txt"

awk -v base="$base" '/^(GET|POST|PUT|PATCH|DELETE) \// { $2 = base $2 } { print }' "$targets" > "$out/targets.txt"
echo "load/run.sh $targets $rate $duration" > "$out/command.txt"

"$here/bin/vegeta" attack -targets="$out/targets.txt" -rate="$rate" -duration="$duration" -max-workers=10000 > "$out/raw.bin"
"$here/bin/vegeta" report < "$out/raw.bin" > "$out/report.txt"
"$here/bin/vegeta" report -type='hist[0,1ms,2ms,5ms,10ms,20ms,50ms,100ms,200ms,500ms,1s]' < "$out/raw.bin" > "$out/histogram.txt"
"$here/bin/vegeta" report -type=json < "$out/raw.bin" > "$out/report.json"

cat "$out/report.txt"
echo "output: $out"
