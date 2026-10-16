#!/bin/sh
# T-82
set -eu

image="$1"
db_host="${SMOKE_DB_HOST:-localhost}"
valkey_host="${SMOKE_VALKEY_HOST:-$db_host}"
network="${SMOKE_NETWORK:-host}"
postgres_image="postgres:18.6@sha256:74935e72241653ca55e0414067e6d8763aceb8a810eb51b452253ec3dcfc4336"
port="${SMOKE_PORT:-4000}"
work="$(mktemp -d)"
publish=""
[ "$network" = host ] || publish="-p ${port}:${port}"
keep="${SMOKE_KEEP:-0}"
trap '[ "$keep" = 1 ] || docker rm -f relay-smoke >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

printf relay > "$work/db-password"
chmod 644 "$work/db-password"
cat > "$work/env" <<ENV
DATABASE_URL=ecto://relay_worker@${db_host}:5432/relay_dev
DATABASE_PASSWORD_FILE=/run/db-password
QUEUE_DATABASE_URL=ecto://relay_queue@${db_host}:5432/relay_dev
QUEUE_DATABASE_PASSWORD_FILE=/run/db-password
POOL_SIZE=5
VALKEY_URL=redis://${valkey_host}:6379
RELAY_HOST=localhost
PORT=${port}
SECRET_KEY_BASE=$(openssl rand -hex 48)
ENV

run() {
  docker run --rm --network "$network" --env-file "$work/env" -v "$work/db-password:/run/db-password:ro" "$@"
}

fail() {
  echo "smoke: $1" >&2
  docker logs relay-smoke 2>&1 | tail -40 >&2 || true
  exit 1
}

psql() {
  docker run --rm -i --network "$network" -e PGPASSWORD=relay "$postgres_image" \
    psql -h "$db_host" -U relay -d relay_dev -v ON_ERROR_STOP=1 "$@"
}

# TN-14
psql -q <priv/repo/bootstrap.sql || fail "bootstrap failed"
for role in relay_migrator relay_worker relay_queue; do
  psql -q -c "ALTER ROLE $role PASSWORD 'relay'" || fail "role password failed"
done

# T-5
run -e RELAY_ROLES=worker -e RELAY_REGION=tr -e "DATABASE_URL=ecto://relay_migrator@${db_host}:5432/relay_dev" \
  "$image" eval 'Relay.Release.migrate()' || fail "migration failed"

# T-3
docker run -d --name relay-smoke --network "$network" $publish --env-file "$work/env" \
  -v "$work/db-password:/run/db-password:ro" -e RELAY_ROLES=api,worker,socket "$image" start >/dev/null

base="http://localhost:${port}"
i=0
until curl -fsS "$base/livez" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "node did not become live"
  sleep 1
done

curl -fsS "$base/readyz" | grep -q '"ok"' || fail "node is not ready"
curl -fsSI "$base/livez" | grep -qi '^correlation-id: ' || fail "correlation id header missing"
curl -fsS "$base/.well-known/security.txt" | grep -q '^Contact: ' || fail "security.txt missing"

# INV-46
if run -e RELAY_ROLES=api -e RELAY_UNKNOWN_SETTING=1 "$image" start >"$work/bad.log" 2>&1; then
  fail "unknown configuration was accepted"
fi
grep -q "unknown environment variables: RELAY_UNKNOWN_SETTING" "$work/bad.log" || fail "unknown configuration was not reported"

echo "smoke: ok"
