#!/bin/sh
# T-82
set -eu

image="$1"
db_host="${SMOKE_DB_HOST:-localhost}"
network="${SMOKE_NETWORK:-host}"
port="${SMOKE_PORT:-4000}"
work="$(mktemp -d)"
publish=""
[ "$network" = host ] || publish="-p ${port}:${port}"
trap 'docker rm -f relay-smoke >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

printf relay > "$work/db-password"
chmod 644 "$work/db-password"
cat > "$work/env" <<ENV
DATABASE_URL=ecto://relay@${db_host}:5432/relay_dev
DATABASE_PASSWORD_FILE=/run/db-password
POOL_SIZE=5
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

# T-5
run -e RELAY_ROLES=worker "$image" eval 'Relay.Release.migrate()' || fail "migration failed"

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
