FROM debian:trixie-slim

RUN apt-get update > /dev/null && \
    apt-get install --yes curl blender > /dev/null && \
    rm -rf /var/lib/apt/lists/*
