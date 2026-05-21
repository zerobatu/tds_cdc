FROM hexpm/elixir:1.18.4-erlang-27.3.4.2-ubuntu-jammy-20260509

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /deps/tds_cdc
COPY mix.exs mix.lock ./
COPY config config
COPY lib lib
RUN mix deps.get && mix compile

WORKDIR /app

COPY example/listener/mix.exs ./mix.exs.tmp
RUN sed 's|path: "../../"|path: "/deps/tds_cdc"|' mix.exs.tmp > mix.exs && rm mix.exs.tmp

COPY example/listener/config config
COPY example/listener/lib lib

RUN mix deps.get && mix compile

CMD ["mix", "run", "--no-halt", "-e", "Listener.start()"]