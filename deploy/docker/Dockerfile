FROM rust:1.99.0-slim-bookworm@sha256:2c3a22f0a5533ea2dd5a16627bc841228151faa2d4de2644ac9987e4a2f1f2fa AS native

ENV SOURCE_DATE_EPOCH=0 \
    CARGO_INCREMENTAL=0

WORKDIR /build

COPY native/pkcs11_port/Cargo.toml native/pkcs11_port/Cargo.lock ./
COPY native/pkcs11_port/src src

RUN cargo build --locked --release

FROM hexpm/elixir:1.20.4-erlang-29.0.6-debian-trixie-20260918-slim@sha256:1907c8e173e9b65657da6ad15a2c618939368d2fc52e90f69984a31561536a7c AS build

ENV MIX_ENV=prod \
    ERL_FLAGS="+deterministic" \
    SOURCE_DATE_EPOCH=0

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY deps deps
COPY config config
COPY lib lib
COPY priv priv
COPY contracts contracts
COPY rel rel
COPY --from=native /build/target/release/pkcs11_port priv/native/pkcs11_port

# TN-65 (7)
RUN sha256sum priv/native/pkcs11_port > priv/native/pkcs11_port.sha256

RUN --network=none mix deps.compile && mix compile --warnings-as-errors && mix release

FROM debian:trixie-20260918-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a

RUN apt-get update \
 && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 libsctp1 ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home /app relay

WORKDIR /app
ENV LANG=C.UTF-8 HOME=/app

COPY --from=build --chown=relay:relay /app/_build/prod/rel/relay ./

USER relay

ENTRYPOINT ["/app/bin/relay"]
CMD ["start"]
