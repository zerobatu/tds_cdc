FROM hexpm/elixir:1.18.4-erlang-27.3.4.2-ubuntu-jammy-20260509

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY mix.exs ./
COPY config config
COPY lib lib

RUN mix deps.get && mix compile

CMD ["mix", "run", "--no-halt"]