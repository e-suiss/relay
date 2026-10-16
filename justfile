compose := "docker compose -f deploy/compose.yaml"

default:
    @just --list

dev: up hsm
    mix deps.get
    mix ecto.setup

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
    export SOFTHSM2_CONF="$PWD/deploy/softhsm/softhsm2.conf"
    softhsm2-util --show-slots | grep -q "Label:.*relay-dev" || softhsm2-util --init-token --free --label relay-dev --pin 1234 --so-pin 12345678

port:
    native/build.sh

test: port
    {{compose}} up -d --wait postgres valkey
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
