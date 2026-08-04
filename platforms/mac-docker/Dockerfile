FROM mcr.microsoft.com/dotnet/sdk:8.0-bookworm-slim

LABEL org.opencontainers.image.title="PlexWeekly Mac Portable" \
      org.opencontainers.image.version="1.0.0" \
      org.opencontainers.image.description="PlexWeekly newsletter service for Docker Desktop on macOS"

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

RUN groupadd --gid 1000 plexweekly \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash plexweekly

WORKDIR /opt/plexweekly
COPY app/ /opt/plexweekly/
RUN chmod +x /opt/plexweekly/entrypoint.sh \
    /opt/plexweekly/run-service.sh \
    /opt/plexweekly/healthcheck.sh \
    /opt/plexweekly/bin/*.sh

ENV PLEXWEEKLY_DATA_DIR=/data \
    PLEXWEEKLY_CONFIG=/data/config.json \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    POWERSHELL_TELEMETRY_OPTOUT=1

VOLUME ["/data"]
EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini","--","/opt/plexweekly/entrypoint.sh"]
