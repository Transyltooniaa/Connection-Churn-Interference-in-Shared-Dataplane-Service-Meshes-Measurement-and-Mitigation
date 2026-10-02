# syntax=docker/dockerfile:1
# ─────────────────────────────────────────────────────────────────────────────
# Multi-stage Dockerfile for the Multi-Ingress Ingestion Proxy (Rust)
# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: Build — statically linked musl binary for minimal runtime image.
FROM rust:1.78-alpine AS builder
RUN apk add --no-cache musl-dev
WORKDIR /build
COPY Cargo.toml Cargo.lock* ./
COPY src/ src/
# Cache deps layer: build an empty lib first, then replace with real sources.
RUN cargo build --release --target x86_64-unknown-linux-musl

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: Runtime — scratch + binary only; no shell, no package manager.
FROM scratch
COPY --from=builder /build/target/x86_64-unknown-linux-musl/release/ingestion-proxy /ingestion-proxy
# Default environment variables (overridden by Kubernetes ConfigMap / env block).
ENV NATS_URL=nats://127.0.0.1:4222 \
    NATS_USER=nats \
    NATS_PASS=nats-local \
    SERVICES=alpha:10001,beta:10002 \
    STREAM_MAX_BYTES=134217728 \
    BACKLOG_LIMIT=10000 \
    MAX_PAYLOAD_BYTES=1048576 \
    RUST_LOG=ingestion_proxy=info,warn
ENTRYPOINT ["/ingestion-proxy"]
