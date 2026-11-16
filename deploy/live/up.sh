#!/bin/sh
# WH-58
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
run="$here/run"
secret=relay-live-secret
token=relay-live-token
access=RELAYLIVEACCESSKEY0
names="DNS:kafka.live.relay.test,DNS:nats.live.relay.test,DNS:nats-token.live.relay.test"
names="$names,DNS:rabbitmq.live.relay.test,DNS:minio.live.relay.test,DNS:localhost"

compose() {
  docker compose -f "$here/compose.yaml" "$@"
}

compose down --volumes --remove-orphans >/dev/null 2>&1 || true
rm -rf "$run"
mkdir -p "$run/minio"

openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=relay live test ca" \
  -keyout "$run/ca.key" -out "$run/ca.crt"
openssl req -newkey rsa:2048 -nodes -subj "/CN=relay live test server" \
  -keyout "$run/server.key" -out "$run/server.csr"
cat > "$run/server.ext" <<EXT
subjectAltName=$names
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EXT
openssl x509 -req -in "$run/server.csr" -CA "$run/ca.crt" -CAkey "$run/ca.key" -CAcreateserial \
  -days 2 -extfile "$run/server.ext" -out "$run/server.crt"
cat "$run/server.key" "$run/server.crt" > "$run/kafka.pem"
cp "$run/server.crt" "$run/minio/public.crt"
cp "$run/server.key" "$run/minio/private.key"

box="$(compose config --images | grep nats-box)"
docker run --rm "$box" nk -gen user -pubout > "$run/nkey"
sed -n 1p "$run/nkey" > "$run/nkey.seed"
nkey="$(sed -n 2p "$run/nkey")"
case "$nkey" in
  U*) ;;
  *) echo "no user nkey was generated" >&2; exit 1 ;;
esac

cat > "$run/nats.conf" <<CONF
port: 4222
http_port: 8222
jetstream {
  store_dir: "/tmp/jetstream"
}
tls {
  cert_file: "/live/run/server.crt"
  key_file: "/live/run/server.key"
}
authorization {
  users: [
    {user: "relay", password: "$secret"}
    {nkey: "$nkey"}
  ]
}
CONF

cat > "$run/nats-token.conf" <<CONF
port: 4222
http_port: 8222
jetstream {
  store_dir: "/tmp/jetstream"
}
tls {
  cert_file: "/live/run/server.crt"
  key_file: "/live/run/server.key"
}
authorization {
  token: "$token"
}
CONF

chmod -R a+rX "$run"

compose up -d --wait

compose exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 \
  --create --topic relay-live --partitions 3 --replication-factor 1

compose exec -T tools nats --tlsca /live/run/ca.crt --server tls://nats.live.relay.test:4222 \
  --user relay --password "$secret" \
  stream add RELAY_LIVE --subjects "relay.live.>" --storage file --defaults
compose exec -T tools nats --tlsca /live/run/ca.crt \
  --server tls://nats-token.live.relay.test:4222 --user "$token" \
  stream add RELAY_LIVE --subjects "relay.live.>" --storage file --defaults

broker="http://10.123.45.14:15672/api"
broker_auth="relay:$secret"

define() {
  curl -fsS -u "$broker_auth" -H "content-type: application/json" -X "$1" "$broker/$2" -d "$3"
}

define PUT "exchanges/%2F/relay.live" '{"type":"topic","durable":true}'
define PUT "exchanges/%2F/relay.live.unbound" '{"type":"topic","durable":true}'
define PUT "queues/%2F/relay-live" '{"durable":true}'
define POST "bindings/%2F/e/relay.live/q/relay-live" '{"routing_key":"relay.live.*"}'

store_auth="$access:$secret"
curl -fsS --cacert "$run/ca.crt" --resolve minio.live.relay.test:9000:10.123.45.15 \
  --aws-sigv4 "aws:amz:us-east-1:s3" --user "$store_auth" \
  -X PUT https://minio.live.relay.test:9000/relay-live
