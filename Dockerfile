# Multi-stage build: download & verify in build stage, runtime in final stage
ARG ARCHIVE_URL="https://github.com/kryptex-miners-org/kryptex-miners/releases/download/krig-1-5-9/krig-miner-1.5.9-linux-x64.tar.gz"
ARG ARCHIVE_NAME="krig-miner-1.5.9-linux-x64.tar.gz"
ARG SHA256=""  # optionally pass --build-arg SHA256=<hex> to verify (verification removed)

################################
# Build stage: download & extract
################################
FROM debian:bookworm-slim AS builder

ARG ARCHIVE_URL
ARG ARCHIVE_NAME
ARG SHA256

ENV DEBIAN_FRONTEND=noninteractive

# Install only tools needed for download / verify / extract
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates wget tar coreutils \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Download and extract to /build/out (checksum verification removed)
RUN set -eux; \
    echo "Downloading ${ARCHIVE_URL}"; \
    wget -O "${ARCHIVE_NAME}" "${ARCHIVE_URL}"; \
    mkdir -p out; \
    # Validate tar members (prevent path traversal) and extract
    python3 - <<'PY' \
import tarfile, os, sys
a = "'''${ARCHIVE_NAME}'''".strip("'")
with tarfile.open(a, 'r:gz') as t:
    for m in t.getmembers():
        if m.name.startswith('/') or '..' in m.name.split('/'):
            print("Invalid member in tar:", m.name, file=sys.stderr)
            sys.exit(2)
    t.extractall('out') 
print("Extraction OK") \
PY

# Inspect output and copy only the files we need; assume binary name contains 'krig-miner'
RUN mkdir -p /build/selected; \
    # find krig-miner in out and copy tree around it
    BIN=$(sh -c "find out -type f -name 'krig-miner*' | head -n1" || true); \
    if [ -z "$BIN" ]; then echo "krig-miner binary not found in archive" >&2; exit 2; fi; \
    echo "Found binary: $BIN"; \
    # copy entire extracted dir to keep lib/ data if needed
    cp -a out /build/selected

################################
# Runtime stage
################################
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# tini for proper signal handling and reaping
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates tini \
  && rm -rf /var/lib/apt/lists/*

# Create non-root user and group
RUN groupadd -r krig && useradd -r -g krig -d /nonexistent -s /usr/sbin/nologin krig

# Copy the prepared files from builder
COPY --from=builder /build/selected/out /opt/krig

# Ensure binary is executable and owned by krig
RUN set -eux; \
    find /opt/krig -type f -exec chmod 0555 {} + || true; \
    find /opt/krig -type d -exec chmod 0755 {} + || true; \
    chown -R krig:krig /opt/krig

# Add entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0555 /usr/local/bin/entrypoint.sh

# Use tini as PID 1 and run entrypoint. Container will run as non-root.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
USER krig

# Default: entrypoint reads WALLET and POOL_URL from env.
CMD []
