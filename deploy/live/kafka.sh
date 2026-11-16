#!/bin/bash
# WH-58
set -euo pipefail

bin=/opt/kafka/bin
config=/live/kafka.properties
secret=relay-live-secret
id="$("$bin/kafka-storage.sh" random-uuid)"

"$bin/kafka-storage.sh" format -t "$id" -c "$config" \
  --add-scram "SCRAM-SHA-256=[name=relay,password=$secret]" \
  --add-scram "SCRAM-SHA-512=[name=relay,password=$secret]"

exec "$bin/kafka-server-start.sh" "$config"
