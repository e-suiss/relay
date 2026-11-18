#!/usr/bin/env bash
# X-37
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
examples="$root/site/examples"
cd "$root"

. "$examples/curl/env.sh"

ran=()
out=$(mktemp)

run() {
  local name=$1
  ran+=("$name.sh")
  echo "::group::curl $name"
  if ! (. "$examples/curl/$name.sh") > "$out"; then
    cat "$out"
    echo "::error::the $name example failed"
    exit 1
  fi
  cat "$out"
  echo
  echo "::endgroup::"
}

expect() {
  if ! jq -e "$1" "$out" > /dev/null; then
    echo "::error::the last example did not answer as the docs describe: $1"
    exit 1
  fi
}

run first-notification
expect '.object == "event" and .status == "accepted" and (.notifications | length) == 1'

for attempt in $(seq 1 30); do
  run decisions
  if jq -e '(.data | length) > 0 and (.data[0].deliveries | length) > 0' "$out" > /dev/null; then break; fi
  echo "waiting for the decision record ($attempt)"
  sleep 2
done
expect '.data[0].object == "notification_decision" and (.data[0].deliveries[0].gates | type) == "string"'

poll() {
  local name=$1 condition=$2
  for attempt in $(seq 1 30); do
    run "$name"
    if jq -e "$condition" "$out" > /dev/null; then return 0; fi
    echo "waiting for $name ($attempt)"
    sleep 2
  done
  echo "::error::$name never answered as the docs describe: $condition"
  exit 1
}

poll test-inbox '(.data | length) > 0 and (.data[0].deliveries | length) > 0'
expect '.data[0].object == "test_inbox_message"'

run seed-quiet-hours
expect '.status == "accepted"'
poll test-inbox '[.data[0].deliveries[] | select(.rule_id != null)] | length > 0'

run idempotency
test "$(grep -ci '^idempotency-replayed: true' "$out")" -eq 1

run discovery
expect '.issuer != null'

run problem
expect '.code == "unknown_field" and .retryable == false'

run error-catalog
expect '.code == "unknown_field" or .title != null'

run cloudevents-mapping
expect '.object == "event_type_mapping" and .state == "active"'

run cloudevents-send
expect '.status == "accepted"'

run mcp-tools
expect '[.result.tools[].name] | index("relay_send") != null'

run mcp-send
expect '.result.resultType == "complete" and (.result.isError // false) == false'

for file in "$examples"/curl/*.sh; do
  name=$(basename "$file")
  if [ "$name" != env.sh ] && [[ " ${ran[*]} " != *" $name "* ]]; then
    echo "::error::$name is shown in the docs but never run"
    exit 1
  fi
done

cd "$root/site"
for example in examples/typescript/*.ts; do
  case "$example" in
    examples/typescript/credentials.ts | *.run.ts) continue ;;
  esac
  runner="${example%.ts}.run.ts"
  if [ -f "$runner" ]; then
    example="$runner"
  fi
  echo "::group::$example"
  node "$example"
  echo "::endgroup::"
done
