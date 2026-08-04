FROM mcr.microsoft.com/dotnet/sdk:8.0-bookworm-slim

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
RUN chmod +x /opt/tautweekly/entrypoint.sh \
    /opt/tautweekly/run-service.sh \
    /opt/tautweekly/healthcheck.sh \
    /opt/tautweekly/bin/*.sh

ENV TAUTWEEKLY_DATA_DIR=/data \
    TAUTWEEKLY_CONFIG=/data/config.json \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    POWERSHELL_TELEMETRY_OPTOUT=1

VOLUME ["/data"]
EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini","--","/opt/tautweekly/entrypoint.sh"]
