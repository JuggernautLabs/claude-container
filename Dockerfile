FROM ghcr.io/hypermemetic/claude-container:latest

# Add sudo and docker CLI
RUN apt-get update && apt-get install -y --no-install-recommends \
    sudo \
    docker.io \
    && rm -rf /var/lib/apt/lists/*
