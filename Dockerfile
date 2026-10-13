FROM ghcr.io/foundry-rs/foundry:v1.8.3 AS foundry

FROM debian:bookworm-slim

ARG TARGETARCH
ARG SUPERCRONIC_VERSION=v0.2.44

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl jq \
 && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
      amd64) sha=6feff7d5eba16a89cf229b7eb644cfae2f03a32c62ca320f17654659315275b6 ;; \
      arm64) sha=ec29b3129ab20100971d21d391150d50398e5caaa33b8652eab919e2c5143057 ;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH:-amd64}"; \
    echo "$sha  /usr/local/bin/supercronic" | sha256sum -c -; \
    chmod +x /usr/local/bin/supercronic

COPY --from=foundry /usr/local/bin/cast /usr/local/bin/cast

RUN useradd --create-home --uid 1000 keeper
WORKDIR /app
COPY --chown=keeper:keeper crontab ./
COPY --chown=keeper:keeper lib ./lib
COPY --chown=keeper:keeper jobs ./jobs
USER keeper

CMD ["supercronic", "-passthrough-logs", "/app/crontab"]
