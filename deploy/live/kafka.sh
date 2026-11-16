#!/bin/bash
# WH-58
set -euo pipefail

bin=/opt/kafka/bin
config=/tmp/server.properties
secret=relay-live-secret
cluster=cmVsYXlsaXZla2Fma2ExMg
listeners="INTERNAL://0.0.0.0:9092,EXTERNAL://0.0.0.0:9093,MTLS://0.0.0.0:9095"
users=()

if [ "$NODE_ID" = 1 ]; then
  listeners="$listeners,CONTROLLER://0.0.0.0:9094"
  users=(
    --add-scram "SCRAM-SHA-256=[name=relay,password=$secret]"
    --add-scram "SCRAM-SHA-512=[name=relay,password=$secret]"
  )
fi

cat /live/kafka.properties > "$config"
cat >> "$config" <<EOF
node.id=$NODE_ID
process.roles=$ROLES
listeners=$listeners
advertised.listeners=INTERNAL://$HOST:9092,EXTERNAL://$HOST:9093,MTLS://$HOST:9095
EOF

"$bin/kafka-storage.sh" format -t "$cluster" -c "$config" "${users[@]}"

exec "$bin/kafka-server-start.sh" "$config"
