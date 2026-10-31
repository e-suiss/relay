compose := "docker compose -f deploy/compose.yaml"
softhsm_modules := "/opt/homebrew/lib/softhsm/libsofthsm2.so /usr/local/lib/softhsm/libsofthsm2.so /usr/lib/softhsm/libsofthsm2.so /usr/lib/x86_64-linux-gnu/softhsm/libsofthsm2.so"

export SOFTHSM2_CONF := justfile_directory() / "deploy/softhsm/softhsm2.conf"

default:
    @just --list

dev: up hsm-keys port
    mix deps.get
    mix ecto.setup
    mix relay.audit.store
    mix relay.dev.seed
    iex -S mix phx.server

up:
    {{compose}} up -d --wait

down:
    {{compose}} down

chaos:
    {{compose}} --profile chaos up -d --wait toxiproxy

access:
    {{compose}} --profile access up -d --wait access

hsm:
    #!/bin/sh
    set -eu
    if ! command -v softhsm2-util >/dev/null; then echo "softhsm2-util not found; install SoftHSM (brew install softhsm, apt install softhsm2)"; exit 1; fi
    mkdir -p deploy/softhsm/tokens
    softhsm2-util --show-slots | grep -q "Label:.*relay-dev" || softhsm2-util --init-token --free --label relay-dev --pin 1234 --so-pin 12345678
    printf 1234 > deploy/softhsm/pin

hsm-keys: hsm
    #!/bin/sh
    set -eu
    module="${PKCS11_MODULE:-}"
    if [ -z "$module" ]; then
      for candidate in {{softhsm_modules}}; do [ -f "$candidate" ] && module="$candidate" && break; done
    fi
    [ -n "$module" ] || { echo "SoftHSM module not found; set PKCS11_MODULE"; exit 1; }
    PKCS11_MODULE="$module" PKCS11_TOKEN=relay-dev PKCS11_PIN_FILE=deploy/softhsm/pin \
      KEY_STORE_KEK_LABEL=kek-dev KEY_STORE_FINGERPRINT_LABEL=fingerprint-dev KEY_STORE_CURSOR_LABEL=cursor-dev KEY_STORE_BLIND_INDEX_LABEL=bidx-dev deploy/hsm-keys.sh

port:
    #!/bin/sh
    set -eu
    native/build.sh
    mkdir -p priv/native
    cp native/pkcs11_port/target/release/pkcs11_port priv/native/pkcs11_port
    cp native/pkcs11_port/target/release/pkcs11_port.sha256 priv/native/pkcs11_port.sha256

test: port
    {{compose}} up -d --wait postgres valkey minio
    mix test --include integration

check:
    mix format --check-formatted
    mix deps.get --check-locked
    mix deps.unlock --check-unused
    mix compile --warnings-as-errors --force
    mix credo --strict
    mix sobelow --config
    mix hex.audit
    mix deps.audit
    mix lint
    mix relay.bench.reductions
    mix dialyzer
    mix docs --warnings-as-errors
    cd native/pkcs11_port && cargo fmt --check
    cd native/pkcs11_port && cargo clippy --locked --all-targets -- -D warnings
    cd native/pkcs11_port && cargo test --locked
    docker compose -f deploy/compose.yaml config -q
    just test

gen:
    mix relay.catalog.gen

load targets="load/targets/health.txt" rate="100/1s" duration="30s":
    load/run.sh {{targets}} {{rate}} {{duration}}

bench:
    mix run bench/hot_paths.exs

image:
    mix deps.get --only prod --check-locked
    docker build -f deploy/docker/Dockerfile -t relay:local .
    SMOKE_DB_HOST=host.docker.internal SMOKE_NETWORK=bridge deploy/smoke.sh relay:local

migrate:
    mix ecto.migrate
