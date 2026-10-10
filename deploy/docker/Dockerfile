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
COPY rel rel

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
