# Stage 1: Build rclone with a Go toolchain that carries the crypto/x509 fix
# (CVE-2026-111943, fixed in Go 1.27.3). The rclone 1.75.2 release binaries are
# built with an older Go. CGO is off, so the result is a static binary that the
# runtime stage can copy without any of the build toolchain.
FROM golang:1.27.3-trixie AS rclone

ARG RCLONE_VER=1.75.2

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# rclone 1.75.2's go.mod pins Go modules the image scan reports as vulnerable:
# go-chi/chi/v5 5.3.1 (CVE-2026-114437), x/net 0.60.0 (CVE-2026-78661,
# CVE-2026-97045) and x/crypto 0.57.0 (GO-2026-5932). They are all minor bumps
# with no API change, so resolve the fixed releases into the module graph
# instead of moving off the rclone release the backup job is tested against.
RUN git clone --depth 1 --branch "v${RCLONE_VER}" https://github.com/rclone/rclone.git . \
    && go get \
        github.com/go-chi/chi/v5@v5.4.0 \
        golang.org/x/crypto@v0.58.1-0.20261009181718-2f1f834330b2 \
        golang.org/x/net@v0.62.0 \
    && go mod tidy \
    && CGO_ENABLED=0 go build -trimpath \
    -ldflags "-s -w -X github.com/rclone/rclone/fs.Version=v${RCLONE_VER}" \
    -o /usr/local/bin/rclone .

# Stage 2: Application image, built on the current Debian stable (trixie).
FROM python:3.14-slim-trixie

# Pick up Debian security updates published after the base image was built.
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone

# Set working directory
WORKDIR /app

# Copy requirements file
COPY requirements.txt .

# Install dependencies, then drop pip/setuptools/wheel: they are only needed
# at build time, and the copies vendored inside pip carry their own CVEs.
RUN pip install --no-cache-dir --upgrade pip setuptools wheel \
    && pip install --no-cache-dir -r requirements.txt \
    && python -m pip uninstall -y pip setuptools wheel \
    && rm -rf /root/.cache/pip

# Set non-root user. shadow >= 4.15 (Debian trixie) creates the home directory
# 0700, which leaves /home/appuser/app unreachable when the container is run
# with an arbitrary uid (the homelab CronJob uses 1036:100 to match the NFS
# export), and python then fails with "[Errno 13] Permission denied" on
# main.py. The source tree is world-readable (0644/0755), so only the home
# directory itself needs opening up.
RUN useradd --create-home appuser \
    && chmod 0755 /home/appuser
USER appuser
WORKDIR /home/appuser/app

# Copy application source
COPY --chown=appuser:appuser . .

# Set entrypoint
ENTRYPOINT ["python", "main.py"]
