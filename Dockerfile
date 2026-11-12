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

# near-cli-rs signs and sends process_due for the NEAR job. Pinned to the last stable release
# before the 0.31 line; update NEAR_CLI_VERSION and both checksums together (from the release's
# .sha256 assets). The gnu build links libudev for Ledger support.
ARG NEAR_CLI_VERSION=v0.30.1
RUN apt-get update \
 && apt-get install -y --no-install-recommends libudev1 \
 && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
      amd64) arch=x86_64; sha=996e9f390d1cc446d17ea24e39c48f6ff906507f2d1dba96fc41f596a7e5de14 ;; \
      arm64) arch=aarch64; sha=0aefe899828005e6356954a8a0870fdeb8ae72e9d9c6ec59a14d2487721e9143 ;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    tarball="near-cli-rs-$arch-unknown-linux-gnu.tar.gz"; \
    curl -fsSL -o "/tmp/$tarball" \
      "https://github.com/near/near-cli-rs/releases/download/${NEAR_CLI_VERSION}/$tarball"; \
    echo "$sha  /tmp/$tarball" | sha256sum -c -; \
    mkdir /tmp/near-cli; \
    tar -xzf "/tmp/$tarball" -C /tmp/near-cli; \
    install -m 0755 "$(find /tmp/near-cli -type f -name near | head -n1)" /usr/local/bin/near; \
    rm -rf /tmp/near-cli "/tmp/$tarball"

RUN useradd --create-home --uid 1000 keeper
WORKDIR /app
COPY --chown=keeper:keeper crontab ./
COPY --chown=keeper:keeper lib ./lib
COPY --chown=keeper:keeper jobs ./jobs
# supercronic execs jobs directly; don't depend on the git file mode surviving merges (see 57333b1).
RUN chmod +x jobs/*.sh
USER keeper

CMD ["supercronic", "-passthrough-logs", "/app/crontab"]
