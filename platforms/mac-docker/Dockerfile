FROM tailscale/tailscale:v1.102.2 AS tailscale-runtime

FROM mcr.microsoft.com/dotnet/sdk:8.0-bookworm-slim

ARG BUILD_VERSION=dev
ARG TARGETARCH

LABEL org.opencontainers.image.title="TautWeekly for Plex Mac Portable" \
      org.opencontainers.image.version="$BUILD_VERSION" \
      org.opencontainers.image.description="TautWeekly for Plex newsletter service for Docker Desktop on macOS" \
      org.opencontainers.image.licenses="MIT AND BSD-3-Clause" \
      io.tautweekly.host-adapter-api="4" \
      io.tautweekly.remote-access="tailscale-funnel"

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get -y upgrade \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gosu \
        imagemagick \
        python3 \
        tini \
        tzdata \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 1000 tautweekly \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash tautweekly

WORKDIR /opt/tautweekly
COPY app/ /opt/tautweekly/
COPY THIRD_PARTY_NOTICES.md /usr/share/doc/tautweekly/THIRD_PARTY_NOTICES.md
COPY manager/ /tmp/tautweekly-manager/
COPY --from=tailscale-runtime /usr/local/bin/tailscale /usr/local/bin/tailscale
COPY --from=tailscale-runtime /usr/local/bin/tailscaled /usr/local/bin/tailscaled
RUN set -eux; \
    manager_arch="${TARGETARCH:-amd64}"; \
    case "$manager_arch" in amd64|arm64) ;; *) echo "Unsupported Mac container architecture: $manager_arch" >&2; exit 1 ;; esac; \
    install -m 0755 "/tmp/tautweekly-manager/tautweekly-manager-linux-$manager_arch" /opt/tautweekly/bin/tautweekly-manager; \
    rm -rf /tmp/tautweekly-manager
RUN chmod +x /opt/tautweekly/entrypoint.sh \
    /opt/tautweekly/run-service.sh \
    /opt/tautweekly/healthcheck.sh \
    /opt/tautweekly/bin/*.sh \
    /opt/tautweekly/bin/tautweekly-manager \
    /opt/tautweekly/bin/tautweekly-funnel

ENV TAUTWEEKLY_DATA_DIR=/data \
    TAUTWEEKLY_CONFIG=/data/config.json \
    TAUTWEEKLY_MANAGER_LISTEN=0.0.0.0:8080 \
    HOME=/tmp/tautweekly/home \
    XDG_CONFIG_HOME=/tmp/tautweekly/config \
    XDG_CACHE_HOME=/tmp/tautweekly/cache \
    XDG_DATA_HOME=/tmp/tautweekly/share \
    DOTNET_BUNDLE_EXTRACT_BASE_DIR=/tmp/tautweekly/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    POWERSHELL_TELEMETRY_OPTOUT=1

VOLUME ["/data", "/var/lib/tautweekly-tailscale"]
EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini","--","/opt/tautweekly/entrypoint.sh"]
