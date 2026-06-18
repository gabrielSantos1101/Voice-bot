ARG CACHE_BUST=1

FROM elixir:1.19-alpine AS build

RUN apk add git

ENV MIX_ENV=prod

WORKDIR /app

# get deps first so we have a cache
ADD mix.exs mix.lock /app/
RUN \
	cd /app && \
	mix local.hex --force && \
	mix local.rebar --force && \
	mix deps.get

# then make a release build (--force guarantees fresh compile)
ADD . /app/
RUN \
	mix compile --force && \
	mix release

FROM elixir:1.19-alpine

RUN apk add --no-cache python3 py3-pip ffmpeg py3-cryptography && \
    python3 -m pip install --break-system-packages --no-cache-dir edge-tts sorrydave

COPY --from=build /app/_build/prod/rel/arcane_voice /opt/arcane_voice

CMD [ "/opt/arcane_voice/bin/arcane_voice", "start" ]
