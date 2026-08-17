FROM golang:1.26.5-bookworm AS manager-build

ARG TARGETARCH
ARG BUILD_VERSION=dev
WORKDIR /src/manager
COPY manager/ ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH="${TARGETARCH:-amd64}" \
    go build -trimpath -buildvcs=false -ldflags "-s -w -X main.version=${BUILD_VERSION}" \
    -o /out/tautweekly-manager ./cmd/tautweekly-manager

FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH
ARG POWERSHELL_VERSION=7.4.16
ARG BUILD_VERSION=dev

LABEL org.opencontainers.image.title="TautWeekly for Plex" \
    org.opencontainers.image.description="Preview-first weekly Plex activity newsletters powered by Tautulli." \
    org.opencontainers.image.url="https://github.com/sparkmoxie/TautWeekly" \
    org.opencontainers.image.source="https://github.com/sparkmoxie/TautWeekly" \
    org.opencontainers.image.documentation="https://sparkmoxie.github.io/TautWeekly/nas-docker/" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.version="$BUILD_VERSION" \
    io.tautweekly.host-adapter-api="2"

RUN apt-get update \
    && apt-get -y upgrade \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gss-ntlmssp \
        gosu \
        imagemagick \
        less \
        libc6 \
        libgcc-s1 \
        libgssapi-krb5-2 \
        libicu72 \
        liblttng-ust1 \
        libssl3 \
        libstdc++6 \
        locales \
        openssh-client \
        python3 \
        tini \
        tzdata \
        util-linux \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    resolved_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$resolved_arch" in \
      amd64) ps_arch='x64'; ps_sha='a3c06b24b548224f1fd0054dc21120464fe5c0dc1709a74134c5eb515d763862' ;; \
      arm64) ps_arch='arm64'; ps_sha='9ef15313aff603031a7d6d62324da5f742f98e1c09172c93b0965f6b4e343f06' ;; \
      *) echo "Unsupported container architecture: $resolved_arch" >&2; exit 1 ;; \
    esac; \
    archive="powershell-${POWERSHELL_VERSION}-linux-${ps_arch}.tar.gz"; \
    curl -fsSL --retry 3 \
      "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/${archive}" \
      -o /tmp/powershell.tar.gz; \
    echo "${ps_sha}  /tmp/powershell.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/microsoft/powershell/7; \
    tar -xzf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7; \
    chmod 755 /opt/microsoft/powershell/7/pwsh; \
    ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh; \
    rm /tmp/powershell.tar.gz; \
    pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'

RUN groupadd --gid 1000 tautweekly \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash tautweekly

WORKDIR /opt/tautweekly
COPY platforms/nas-docker/app/ /opt/tautweekly/
COPY --from=manager-build /out/tautweekly-manager /opt/tautweekly/bin/tautweekly-manager
RUN chmod +x /opt/tautweekly/entrypoint.sh \
    /opt/tautweekly/run-service.sh \
    /opt/tautweekly/healthcheck.sh \
    /opt/tautweekly/bin/*.sh \
    /opt/tautweekly/bin/tautweekly-manager

ENV TAUTWEEKLY_DATA_DIR=/data \
    TAUTWEEKLY_CONFIG=/data/config.json \
    TAUTWEEKLY_MANAGER_LISTEN=0.0.0.0:8080 \
    HOME=/tmp/tautweekly/home \
    XDG_CONFIG_HOME=/tmp/tautweekly/config \
    XDG_CACHE_HOME=/tmp/tautweekly/cache \
    XDG_DATA_HOME=/tmp/tautweekly/share \
    DOTNET_BUNDLE_EXTRACT_BASE_DIR=/tmp/tautweekly/dotnet \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    POWERSHELL_TELEMETRY_OPTOUT=1

VOLUME ["/data"]
EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini","--","/opt/tautweekly/entrypoint.sh"]
