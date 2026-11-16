#!/bin/sh
# WH-58
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
run="$here/run"
secret=relay-live-secret
token=relay-live-token
access=RELAYLIVEACCESSKEY0
names="DNS:kafka.live.relay.test,DNS:kafka-2.live.relay.test,DNS:kafka-3.live.relay.test"
names="$names,DNS:nats.live.relay.test,DNS:nats-token.live.relay.test"
names="$names,DNS:nats-mtls.live.relay.test,DNS:rabbitmq.live.relay.test"
names="$names,DNS:minio.live.relay.test,DNS:localhost"

compose() {
  docker compose -f "$here/compose.yaml" "$@"
}

issue() {
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$2" -keyout "$run/$1.key" -out "$run/$1.csr"
  openssl x509 -req -in "$run/$1.csr" -CA "$run/ca.crt" -CAkey "$run/ca.key" -CAcreateserial \
    -days 2 -extfile "$run/$1.ext" -out "$run/$1.crt"
}

compose down --volumes --remove-orphans >/dev/null 2>&1 || true
rm -rf "$run"
mkdir -p "$run/minio"

openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=relay live test ca" \
  -keyout "$run/ca.key" -out "$run/ca.crt"
cat > "$run/server.ext" <<EXT
subjectAltName=$names
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EXT
cat > "$run/client.ext" <<EXT
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
EXT
issue server "relay live test server"
issue client relay-client
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

server() {
  cat > "$run/$1.conf" <<CONF
port: 4222
http_port: 8222
jetstream {
  store_dir: "/tmp/jetstream"
}
tls {
  cert_file: "/live/run/server.crt"
  key_file: "/live/run/server.key"
  $2
}
$3
CONF
}

server nats "" "authorization {
  users: [
    {user: \"relay\", password: \"$secret\"}
    {nkey: \"$nkey\"}
  ]
}"
server nats-token "" "authorization {
  token: \"$token\"
}"
server nats-mtls "ca_file: \"/live/run/ca.crt\"
  verify: true" ""

chmod -R a+rX "$run"

compose up -d --wait

compose exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 \
  --create --topic relay-live --partitions 3 --replication-factor 1
compose exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 \
  --describe --topic relay-live

stream() {
  host="$1"
  shift
  compose exec -T tools nats --tlsca /live/run/ca.crt --server "tls://$host:4222" "$@" \
    stream add RELAY_LIVE --subjects "relay.live.>" --storage file --defaults
}

stream nats.live.relay.test --user relay --password "$secret"
stream nats-token.live.relay.test --user "$token"
stream nats-mtls.live.relay.test --tlscert /live/run/client.crt --tlskey /live/run/client.key

broker="http://10.123.45.14:15672/api"
broker_auth="relay:$secret"

define() {
  curl -fsS -u "$broker_auth" -H "content-type: application/json" -X "$1" "$broker/$2" -d "$3"
}

define PUT "exchanges/%2F/relay.live" '{"type":"topic","durable":true}'
define PUT "exchanges/%2F/relay.live.unbound" '{"type":"topic","durable":true}'
define PUT "queues/%2F/relay-live" '{"durable":true}'
define POST "bindings/%2F/e/relay.live/q/relay-live" '{"routing_key":"relay.live.*"}'
define PUT "users/relay-client" '{"password_hash":"","tags":""}'
define PUT "permissions/%2F/relay-client" '{"configure":".*","write":".*","read":".*"}'

store_auth="$access:$secret"
curl -fsS --cacert "$run/ca.crt" --resolve minio.live.relay.test:9000:10.123.45.15 \
  --aws-sigv4 "aws:amz:us-east-1:s3" --user "$store_auth" \
  -X PUT https://minio.live.relay.test:9000/relay-live
