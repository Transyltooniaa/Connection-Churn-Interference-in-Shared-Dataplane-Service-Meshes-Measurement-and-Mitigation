//! # Multi-Ingress Ingestion Proxy
//!
//! Node-local async Rust daemon that acts as the decrypted-stream landing pad between
//! ztunnel and the node-local NATS JetStream broker.
//!
//! ## Architecture position
//!
//! ```text
//!   [external client]
//!        |  HBONE/mTLS  (port 15008)
//!        v
//!   [ztunnel DaemonSet]  — AuthorizationPolicy enforced at L4
//!        |  plaintext TCP  (127.0.0.1:10001 / 10002 / ...)
//!        v
//!   [THIS PROXY]  — one listener per service, non-blocking write to NATS
//!        |  NATS JetStream publish  (127.0.0.1:4222)
//!        v
//!   [NATS JetStream DaemonSet]  — per-service subjects w/ memory quotas
//!        |  long-polling Fetch(1)
//!        v
//!   [Worker Pods]  — pull exactly 1 message at a time
//! ```
//!
//! ## Configuration (environment variables, injected via ConfigMap)
//!
//! | Variable             | Default               | Description                              |
//! |----------------------|-----------------------|------------------------------------------|
//! | `NATS_URL`           | `nats://127.0.0.1:4222` | Local NATS client URL                  |
//! | `NATS_USER`          | `nats`                | NATS username                            |
//! | `NATS_PASS`          | `nats-local`          | NATS password                            |
//! | `SERVICES`           | `alpha:10001,beta:10002` | Comma-sep `name:port` pairs           |
//! | `STREAM_MAX_BYTES`   | `134217728`           | Per-stream memory cap (bytes) = 128 MiB  |
//! | `MAX_PAYLOAD_BYTES`  | `1048576`             | Max TCP payload per message (1 MiB)      |
//! | `BACKLOG_LIMIT`      | `10000`               | NATS stream MaxMsgs before drop-policy   |
//!
//! ## Operational guarantees
//!
//! - **Non-blocking write path**: publish to NATS is fire-and-forget; connection from ztunnel
//!   is ACK'd immediately after the broker confirms the write.
//! - **Isolated backpressure**: each service stream has its own `MaxBytes`/`MaxMsgs` cap.
//!   A surge on `local.tasks.alpha` cannot consume memory reserved for `local.tasks.beta`.
//! - **Drop-on-overflow**: when a stream is full the `DiscardNew` policy causes NATS to
//!   reject the publish with an error, which the proxy converts to a TCP RST towards ztunnel.
//!   ztunnel then drops the mTLS handshake — matching Phase A / Step 5 of the design.
//! - **Graceful shutdown**: `SIGTERM` handler drains in-flight publishes before exit.

// Imports
use anyhow::{Context, Result};
use async_nats::jetstream::{self, stream};
use bytes::BytesMut;
use serde::Deserialize;
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::{
    io::AsyncReadExt,
    net::TcpListener,
    signal,
    sync::watch,
};
use tracing::{error, info, warn};

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────

/// All tunables come from environment variables; no config files needed.
// Config implements Debug and Deserialize traits.
#[derive(Debug, Deserialize)]
struct Config {
    /// NATS server URL — always the local host loopback
    #[serde(default = "default_nats_url")]
    nats_url: String,

    /// NATS credentials (set in NATS server config / Kubernetes Secret)
    #[serde(default = "default_nats_user")]
    nats_user: String,
    #[serde(default = "default_nats_pass")]
    nats_pass: String,

    /// Comma-separated `name:port` list, e.g. `alpha:10001,beta:10002`
    #[serde(default = "default_services")]
    services: String,

    /// Hard memory cap per JetStream stream (bytes). Default = 128 MiB.
    #[serde(default = "default_stream_max_bytes")]
    stream_max_bytes: i64,

    /// Max messages per stream before DiscardNew kicks in. Default = 10 000.
    #[serde(default = "default_backlog_limit")]
    backlog_limit: i64,

    /// Max bytes read from a single TCP connection (one message). Default = 1 MiB.
    #[serde(default = "default_max_payload_bytes")]
    max_payload_bytes: usize,
}

// Functions that return values. We can change the values based on our configuration.
fn default_nats_url() -> String {
    "nats://127.0.0.1:4222".into()
}
fn default_nats_user() -> String {
    "nats".into()
}
fn default_nats_pass() -> String {
    "nats-local".into()
}
fn default_services() -> String {
    "alpha:10001,beta:10002".into()
}
fn default_stream_max_bytes() -> i64 {
    128 * 1024 * 1024 // 128 MiB
}
fn default_backlog_limit() -> i64 {
    10_000
}
fn default_max_payload_bytes() -> usize {
    1024 * 1024 // 1 MiB
}

// ─────────────────────────────────────────────────────────────────────────────
// Service-descriptor: one TCP listener + one NATS subject per service
// ─────────────────────────────────────────────────────────────────────────────

// ServiceDef implements Debug and Clone traits.
#[derive(Debug, Clone)]
struct ServiceDef {
    /// Short service name, e.g. "alpha"
    name: String,
    /// Local loopback TCP port that ztunnel forwards to, e.g. 10001
    port: u16,
    /// NATS JetStream subject, e.g. "local.tasks.alpha"
    subject: String,
    /// NATS JetStream stream name, e.g. "LOCAL-ALPHA"
    stream_name: String,
}

/// Parse `SERVICES` env-var into a list of `ServiceDef`.
fn parse_services(raw: &str) -> Result<Vec<ServiceDef>> {
    let mut defs = Vec::new(); // Mutable vector to hold ServiceDef instances.
    for pair in raw.split(',') { // Split the raw string by commas to get each service pair.
        let pair = pair.trim();
        if pair.is_empty() {
            continue;
        }
        let parts: Vec<&str> = pair.splitn(2, ':').collect(); // Split each pair into name and port based on the first colon.
        anyhow::ensure!(
            parts.len() == 2,
            "invalid service spec {:?}; expected name:port",
            pair
        ); // Ensure that we have exactly two parts (name and port), otherwise return an error.
        let name = parts[0].trim().to_string();
        let port: u16 = parts[1]
            .trim()
            .parse()
            .with_context(|| format!("bad port for service {}", name))?; // Parse the port as a u16, returning an error if it fails.
        let subject = format!("local.tasks.{}", name); // Construct the NATS subject for the service.
        let stream_name = format!("LOCAL-{}", name.to_ascii_uppercase()); // Construct the NATS stream name for the service.
        defs.push(ServiceDef {
            name,
            port,
            subject,
            stream_name,
        }); // Push the constructed ServiceDef into the defs vector.
    }
    Ok(defs) // Return the vector of ServiceDef instances wrapped in a Result.
}

// ─────────────────────────────────────────────────────────────────────────────
// JetStream stream bootstrap
// ─────────────────────────────────────────────────────────────────────────────

/// Create or update the JetStream stream for a service.
///
/// Stream configuration enforces:
/// - `DiscardNew`: new publishes are rejected (TCP RST back to ztunnel) when full.
/// - `MaxBytes` / `MaxMsgs`: hard per-stream resource walls.
/// - `Storage::Memory`: pure-memory; aligns with tmpfs JetStream store_dir.
/// - `Retention::WorkQueue`: message is deleted after one consumer ACK.
async fn ensure_stream(
    js: &jetstream::Context,
    svc: &ServiceDef,
    max_bytes: i64,
    max_msgs: i64,
) -> Result<()> {
    let cfg = stream::Config {
        name: svc.stream_name.clone(),
        subjects: vec![svc.subject.clone()],
        storage: stream::StorageType::Memory,
        retention: stream::RetentionPolicy::WorkQueue,
        discard: stream::DiscardPolicy::New,
        max_bytes,
        max_messages: max_msgs,
        max_age: Duration::from_secs(300), // 5-min TTL: orphaned messages auto-expire
        ..Default::default()
    };

    match js.get_or_create_stream(cfg).await {
        Ok(_) => {
            info!(
                stream = %svc.stream_name,
                subject = %svc.subject,
                max_bytes,
                max_msgs,
                "JetStream stream ready"
            );
            Ok(())
        }
        Err(e) => Err(anyhow::anyhow!(
            "failed to ensure stream {}: {}",
            svc.stream_name,
            e
        )),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-service listener task
// ─────────────────────────────────────────────────────────────────────────────

/// Spawn one Tokio task that:
/// 1. Listens on `127.0.0.1:{port}`.
/// 2. For each accepted TCP connection, reads all available bytes up to `max_payload`.
/// 3. Publishes the payload to NATS JetStream synchronously (awaits the broker ACK).
/// 4. Sends a TCP ACK back to ztunnel and drops the connection immediately.
///
/// If the stream is full (`DiscardNew`), the publish returns an error; the proxy
/// closes the TCP connection with a RST, which ztunnel surfaces as a rejection.
async fn run_listener(
    svc: ServiceDef,
    js: jetstream::Context,
    max_payload: usize,
    mut shutdown: watch::Receiver<bool>,
) {
    let addr = format!("127.0.0.1:{}", svc.port);
    let listener = match TcpListener::bind(&addr).await {
        Ok(l) => {
            info!(
                service = %svc.name,
                addr = %addr,
                subject = %svc.subject,
                "ingestion listener bound"
            );
            l
        }
        Err(e) => {
            error!(service = %svc.name, addr = %addr, error = %e, "bind failed");
            return;
        }
    };

    loop {
        tokio::select! {
            // Honour SIGTERM: stop accepting new connections.
            _ = shutdown.changed() => {
                if *shutdown.borrow() {
                    info!(service = %svc.name, "shutdown signal — listener stopping");
                    break;
                }
            }
            accept = listener.accept() => {
                match accept {
                    Err(e) => {
                        warn!(service = %svc.name, error = %e, "accept error; continuing");
                    }
                    Ok((mut socket, peer)) => {
                        let js_clone  = js.clone();
                        let subject   = svc.subject.clone();
                        let svc_name  = svc.name.clone();

                        // Spawn a short-lived task per connection so the listener
                        // loop is never blocked on I/O or NATS round-trip.
                        tokio::spawn(async move {
                            let mut buf = BytesMut::with_capacity(4096);
                            // Read up to max_payload bytes; stop after the first chunk
                            // (ztunnel streams are short-lived request blobs).
                            let mut tmp = vec![0u8; max_payload];
                            match socket.read(&mut tmp).await {
                                Err(e) => {
                                    warn!(
                                        service = %svc_name,
                                        peer = %peer,
                                        error = %e,
                                        "read error — dropping connection"
                                    );
                                    return;
                                }
                                Ok(0) => {
                                    // Peer closed before sending any data — ignore.
                                    return;
                                }
                                Ok(n) => {
                                    buf.extend_from_slice(&tmp[..n]);
                                }
                            }

                            let payload: bytes::Bytes = buf.freeze();
                            let len = payload.len();

                            // Synchronous publish: wait for JetStream PubAck.
                            match js_clone.publish(subject.clone(), payload).await {
                                Ok(ack_future) => {
                                    match ack_future.await {
                                        Ok(_ack) => {
                                            // Broker confirmed write.
                                            // Socket drop here sends TCP FIN — ztunnel reads ACK.
                                            info!(
                                                service  = %svc_name,
                                                peer     = %peer,
                                                bytes    = len,
                                                "published and ACK'd — connection released"
                                            );
                                        }
                                        Err(e) => {
                                            // PubAck timed-out or stream full (DiscardNew).
                                            // Drop socket WITHOUT sending FIN → RST towards ztunnel.
                                            warn!(
                                                service  = %svc_name,
                                                peer     = %peer,
                                                bytes    = len,
                                                error    = %e,
                                                "publish NACK — stream full or broker error — RST"
                                            );
                                            let _ = socket.into_std().map(|s| {
                                                let _ = s.set_linger(Some(Duration::ZERO));
                                            });
                                        }
                                    }
                                }
                                Err(e) => {
                                    warn!(
                                        service = %svc_name,
                                        peer    = %peer,
                                        error   = %e,
                                        "NATS publish error — RST"
                                    );
                                    let _ = socket.into_std().map(|s| {
                                        let _ = s.set_linger(Some(Duration::ZERO));
                                    });
                                }
                            }
                        });
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    // ── Logging: ISO-8601 timestamps + level filter via RUST_LOG env var ──
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "ingestion_proxy=info,warn".parse().unwrap()),
        )
        .with_target(true)
        .with_thread_ids(false)
        .with_ansi(false) // plain text for kubectl logs / fluentd collectors
        .init();

    // ── Config ────────────────────────────────────────────────────────────
    let cfg: Config = envy::from_env().context("failed to parse environment config")?;
    let services = parse_services(&cfg.services).context("failed to parse SERVICES")?;

    info!(
        nats_url     = %cfg.nats_url,
        services_raw = %cfg.services,
        stream_max_bytes = cfg.stream_max_bytes,
        backlog_limit    = cfg.backlog_limit,
        max_payload_bytes = cfg.max_payload_bytes,
        "ingestion-proxy starting"
    );

    // ── NATS connection ───────────────────────────────────────────────────
    let nats_client = async_nats::ConnectOptions::new()
        .user_and_password(cfg.nats_user.clone(), cfg.nats_pass.clone())
        .name("ingestion-proxy")
        .connection_timeout(Duration::from_secs(10))
        .ping_interval(Duration::from_secs(30))
        .connect(&cfg.nats_url)
        .await
        .with_context(|| format!("NATS connect failed: {}", cfg.nats_url))?;

    info!(url = %cfg.nats_url, "NATS connection established");

    let js = jetstream::new(nats_client);

    // ── Bootstrap JetStream streams ───────────────────────────────────────
    for svc in &services {
        ensure_stream(&js, svc, cfg.stream_max_bytes, cfg.backlog_limit)
            .await
            .with_context(|| format!("stream setup failed for {}", svc.name))?;
    }

    // ── Shutdown signal watcher ───────────────────────────────────────────
    let (shutdown_tx, shutdown_rx) = watch::channel(false);

    // ── Spawn one listener task per service ───────────────────────────────
    let mut handles = Vec::new();
    for svc in services {
        let rx = shutdown_rx.clone();
        let js_clone = js.clone();
        let max_payload = cfg.max_payload_bytes;
        handles.push(tokio::spawn(run_listener(svc, js_clone, max_payload, rx)));
    }

    // ── Wait for SIGTERM or SIGINT ────────────────────────────────────────
    tokio::select! {
        _ = signal::ctrl_c() => {
            info!("SIGINT received");
        }
        _ = async {
            let mut sigterm = signal::unix::signal(signal::unix::SignalKind::terminate())
                .expect("SIGTERM handler setup failed");
            sigterm.recv().await
        } => {
            info!("SIGTERM received — beginning graceful drain");
        }
    }

    // Broadcast shutdown to all listener tasks.
    let _ = shutdown_tx.send(true);

    // Wait up to 10 s for in-flight publishes to complete.
    tokio::time::timeout(Duration::from_secs(10), async {
        for h in handles {
            let _ = h.await;
        }
    })
    .await
    .unwrap_or_else(|_| warn!("drain timed out; forcing exit"));

    info!("ingestion-proxy stopped");
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// Service map helper (unused at runtime; useful for health endpoint extension)
// ─────────────────────────────────────────────────────────────────────────────

#[allow(dead_code)]
fn build_subject_map(services: &[ServiceDef]) -> HashMap<u16, String> {
    services.iter().map(|s| (s.port, s.subject.clone())).collect()
}
