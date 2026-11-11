#!/bin/sh
# T-68
set -eu

report="$1"
type="$2"
here="$(cd "$(dirname "$0")" && pwd)"
budgets="$here/../priv/observability/budgets.json"

budget_ms="$(jq -er --arg t "$type" '.types[] | select(.type == $t) | .latency_ms' "$budgets")"
p99_ms="$(jq -er '.latencies["99th"] / 1000000 | floor' "$report")"
echo "$type: p99 ${p99_ms} ms, budget ${budget_ms} ms"

if [ "$p99_ms" -gt "$budget_ms" ]; then
  title="Performance budget exceeded: $type"
  open="$(gh issue list --state open --search "\"$title\" in:title" --json number --jq 'length')"

  if [ "$open" = "0" ]; then
    gh issue create --title "$title" --body "The nightly load run measured a p99 latency of ${p99_ms} ms for \`$type\` requests; the budget in \`priv/observability/budgets.json\` is ${budget_ms} ms. Run: ${RUN_URL:-unknown}."
  fi
fi
