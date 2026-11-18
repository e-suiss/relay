#!/bin/sh
# OP-87
# T-5
# IN-34
set -eu

out="${1:-load/output/drain}"
base="${DRAIN_BASE_URL:-http://127.0.0.1:4000}"
mkdir -p "$out"

fail() {
  echo "drain: $1" >&2
  tail -n 80 "$out/node-1.log" >&2 || true
  exit 1
}

node_pid() {
  pgrep -f 'beam.smp.*phx.server' | head -n 1
}

start_node() {
  nohup mix phx.server > "$1" 2>&1 &
  i=0
  until curl -fsS "$base/readyz" 2>/dev/null | grep -q '"ok"'; do
    i=$((i + 1))
    [ "$i" -lt 180 ] || fail "the node did not become ready"
    sleep 1
  done
}

start_node "$out/node-1.log"
mix relay.dev.drain traffic --base "$base" --seconds 90 --rate 20 --out "$out/accepted.txt" > "$out/traffic.log" 2>&1 &
traffic=$!
sleep 15

pid="$(node_pid)"
[ -n "$pid" ] || fail "no node process"
started=$(date +%s)
kill -TERM "$pid"
sleep 2

[ "$(curl -s -o /dev/null -w '%{http_code}' "$base/readyz")" = 503 ] || fail "readiness did not answer 503 right after SIGTERM"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$base/livez")" = 200 ] || fail "the node stopped serving before the load balancer wait"

while kill -0 "$pid" 2>/dev/null; do
  [ $(($(date +%s) - started)) -le 75 ] || fail "the node did not stop within the 75 s grace period"
  sleep 1
done
stopped=$(($(date +%s) - started))
echo "drain: the node stopped ${stopped} s after SIGTERM"
[ "$stopped" -ge 10 ] || fail "the node stopped before the 10 s load balancer wait"

line() {
  grep -n "$1" "$out/node-1.log" | head -n 1 | cut -d: -f1
}

readiness="$(line 'drain: readiness withdrawn')"
queues="$(line 'drain: queues stopped taking jobs')"
jobs="$(line 'drain: running jobs finished')"
realtime="$(line 'drain: realtime connections closed')"
[ -n "$readiness" ] && [ -n "$queues" ] && [ -n "$jobs" ] && [ -n "$realtime" ] || fail "a drain phase is missing from the log"
[ "$readiness" -lt "$queues" ] && [ "$queues" -lt "$jobs" ] && [ "$jobs" -lt "$realtime" ] || fail "the drain phases ran out of order"

start_node "$out/node-2.log"
wait "$traffic" || { cat "$out/traffic.log" >&2; fail "the traffic run failed"; }
cat "$out/traffic.log"
mix relay.dev.drain verify --base "$base" --out "$out/accepted.txt" --timeout 180 || fail "an accepted event was lost"
kill -TERM "$(node_pid)" 2>/dev/null || true
echo "drain: ok"
