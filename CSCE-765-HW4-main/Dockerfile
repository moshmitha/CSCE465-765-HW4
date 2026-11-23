FROM python:3.12.16-slim-trixie
RUN apt-get update \
 && apt-get install -y --no-install-recommends socat curl \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /data
WORKDIR /lab
