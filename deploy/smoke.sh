#!/bin/sh
# T-82
set -eu

base_image="$1"
image="relay-smoke-hsm:$$"
hsm_builder="relay-smoke-hsm-$$"
db_host="${SMOKE_DB_HOST:-localhost}"
valkey_host="${SMOKE_VALKEY_HOST:-$db_host}"
network="${SMOKE_NETWORK:-host}"
postgres_image="postgres:18.6@sha256:74935e72241653ca55e0414067e6d8763aceb8a810eb51b452253ec3dcfc4336"
port="${SMOKE_PORT:-4000}"
work="$(mktemp -d)"
publish=""
[ "$network" = host ] || publish="-p ${port}:${port}"
keep="${SMOKE_KEEP:-0}"
trap '[ "$keep" = 1 ] || docker rm -f relay-smoke >/dev/null 2>&1 || true; docker rm -f "$hsm_builder" >/dev/null 2>&1 || true; docker rmi "$image" >/dev/null 2>&1 || true; rm -rf "$work" 2>/dev/null || true' EXIT

printf relay > "$work/db-password"
chmod 644 "$work/db-password"
cat > "$work/env" <<ENV
DATABASE_URL=ecto://relay_worker@${db_host}:5432/relay_dev
DATABASE_PASSWORD_FILE=/run/db-password
QUEUE_DATABASE_URL=ecto://relay_queue@${db_host}:5432/relay_dev
QUEUE_DATABASE_PASSWORD_FILE=/run/db-password
MAINT_DATABASE_URL=ecto://relay_maint@${db_host}:5432/relay_dev
MAINT_DATABASE_PASSWORD_FILE=/run/db-password
POOL_SIZE=5
VALKEY_URL=redis://${valkey_host}:6379
RELAY_HOST=localhost
PORT=${port}
SECRET_KEY_BASE=$(openssl rand -hex 48)
PKCS11_MODULE=/usr/lib/softhsm/libsofthsm2.so
PKCS11_TOKEN=relay-smoke
PKCS11_PIN_FILE=/run/softhsm/pin
SOFTHSM2_CONF=/run/softhsm/softhsm2.conf
ENV

run() {
  docker run --rm --network "$network" --env-file "$work/env" -v "$work/db-password:/run/db-password:ro" \
    -v "$work/softhsm:/run/softhsm" "$@"
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

# TN-63
docker run --name "$hsm_builder" --network "$network" --user root --entrypoint sh "$base_image" -c \
  'apt-get update -qq && apt-get install -y -qq --no-install-recommends softhsm2 >/dev/null && rm -rf /var/lib/apt/lists/*' \
  || fail "softhsm install failed"
docker commit -c 'USER relay' -c 'ENTRYPOINT ["/app/bin/relay"]' -c 'CMD ["start"]' "$hsm_builder" "$image" >/dev/null
mkdir -p "$work/softhsm/tokens"
printf 'directories.tokendir = /run/softhsm/tokens\nobjectstore.backend = file\nlog.level = ERROR\n' > "$work/softhsm/softhsm2.conf"
printf 1234 > "$work/softhsm/pin"
chmod -R a+rwX "$work/softhsm"
run --entrypoint softhsm2-util "$image" --init-token --free --label relay-smoke --pin 1234 --so-pin 12345678 >/dev/null \
  || fail "token init failed"

bootstrap() {
  run -e RELAY_ROLES=worker -e "ADMIN_DATABASE_URL=ecto://relay@${db_host}:5432/relay_dev" \
    -e ADMIN_DATABASE_PASSWORD_FILE=/run/db-password "$image" eval 'Relay.Release.bootstrap()'
}

# TN-14
bootstrap || fail "bootstrap failed"
for role in relay_migrator relay_worker relay_queue relay_maint; do
  psql -q -c "ALTER ROLE $role PASSWORD 'relay'" || fail "role password failed"
done

# T-5
run -e RELAY_ROLES=worker -e RELAY_REGION=tr -e "DATABASE_URL=ecto://relay_migrator@${db_host}:5432/relay_dev" \
  "$image" eval 'Relay.Release.migrate()' || fail "migration failed"

# OP-69 (1)
bootstrap || fail "post-migration bootstrap failed"
psql -q -c "ALTER FUNCTION relay_ops.orphan_check() OWNER TO relay_migrator" || fail "owner change failed"
if run -e RELAY_ROLES=worker "$image" start >"$work/owner.log" 2>&1; then
  fail "a node started with a relay_ops function not owned by relay_maint"
fi
grep -q "relay_ops ownership check failed" "$work/owner.log" || { cat "$work/owner.log" >&2; fail "the ownership check did not stop the node"; }
bootstrap || fail "bootstrap did not restore the relay_ops owner"
[ "$(psql -tA -c "SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = 'relay_ops.orphan_check()'::regprocedure")" = relay_maint ] \
  || fail "bootstrap did not restore the relay_ops owner"

# T-3
docker run -d --name relay-smoke --network "$network" $publish --env-file "$work/env" \
  -v "$work/db-password:/run/db-password:ro" -v "$work/softhsm:/run/softhsm" \
  -e RELAY_ROLES=api,worker,socket "$image" start >/dev/null

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

# TN-63
# TN-65 (7)
keys_ping='{:ok, _} = Application.ensure_all_started(:crypto); {:ok, _} = Relay.Keys.Port.start_link(Application.fetch_env!(:relay, Relay.Keys.Port)); IO.puts(case Relay.Keys.Port.ping(), do: (:ok -> "keys: ok"; {:error, e} -> "keys: #{e.code}"))'
run -e RELAY_ROLES=worker "$image" eval "$keys_ping" >"$work/keys.log" 2>&1 || { cat "$work/keys.log" >&2; fail "key store check failed"; }
grep -q '^keys: ok$' "$work/keys.log" || { cat "$work/keys.log" >&2; fail "key store did not answer"; }

program="$(run -e RELAY_ROLES=worker "$image" eval 'IO.puts(Application.app_dir(:relay, "priv/native/pkcs11_port"))' | tail -1)"
printf '#!/bin/sh\nexit 0\n' > "$work/replaced"
chmod 755 "$work/replaced"
run -e RELAY_ROLES=worker -v "$work/replaced:$program:ro" "$image" eval "$keys_ping" >"$work/replaced.log" 2>&1 || true
grep -q '^keys: key_store_integrity$' "$work/replaced.log" \
  || { cat "$work/replaced.log" >&2; fail "a replaced key store program was not refused"; }

if docker logs relay-smoke 2>&1 | grep -q "key store"; then
  fail "the key store failed on the node"
fi

echo "smoke: ok"
