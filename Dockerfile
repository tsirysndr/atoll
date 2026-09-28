# Atoll PDS built for SQLite: single node, one container owning /data.
ARG ELIXIR_IMAGE="hexpm/elixir:1.19.5-erlang-28.5.0.5-debian-bookworm-20260824-slim"
ARG RUNNER_IMAGE="debian:bookworm-20260918-slim"

FROM ${ELIXIR_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential ca-certificates git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# The Ecto adapter is selected at build time; see docs/sqlite.md.
ENV MIX_ENV="prod" \
    ATOLL_DATABASE="sqlite"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

RUN mix assets.deploy
RUN mix compile

COPY config/runtime.exs config/
RUN mix release

FROM ${RUNNER_IMAGE} AS runner

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
       ca-certificates curl libncurses6 libstdc++6 locales openssl \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG="en_US.UTF-8" \
    LANGUAGE="en_US:en" \
    LC_ALL="en_US.UTF-8"

ENV MIX_ENV="prod" \
    ATOLL_DATABASE="sqlite" \
    PHX_SERVER="true" \
    PORT="4000" \
    DATABASE_PATH="/data/atoll.sqlite3"

WORKDIR /app

RUN install -d -o nobody -g root -m 0750 /data
VOLUME ["/data"]

# mix.exs sets build_path to _build/sqlite/prod, under which Mix nests MIX_ENV.
COPY --from=builder --chown=nobody:root /app/_build/sqlite/prod/prod/rel/atoll ./
COPY ops/docker/entrypoint.sh /app/bin/docker-entrypoint.sh
RUN chmod 0755 /app/bin/docker-entrypoint.sh

USER nobody

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null

ENTRYPOINT ["/app/bin/docker-entrypoint.sh"]
CMD ["start"]
