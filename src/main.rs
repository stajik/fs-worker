mod activities;

use std::str::FromStr;

use temporalio_client::{Client, ClientOptions, Connection, ConnectionOptions};
use temporalio_common::{
    telemetry::TelemetryOptions,
    worker::{WorkerDeploymentOptions, WorkerDeploymentVersion, WorkerTaskTypes},
};
use temporalio_sdk::{Worker, WorkerOptions};
use temporalio_sdk_core::{CoreRuntime, RuntimeOptions, Url};

use activities::FsWorkerActivities;

/// Temporal server address — overridable via `TEMPORAL_HOST` env var.
fn temporal_host() -> String {
    std::env::var("TEMPORAL_HOST").unwrap_or_else(|_| "http://localhost:7233".to_string())
}

/// Temporal namespace — overridable via `TEMPORAL_NAMESPACE` env var.
fn temporal_namespace() -> String {
    std::env::var("TEMPORAL_NAMESPACE").unwrap_or_else(|_| "default".to_string())
}

/// Task queue this worker listens on — overridable via `TEMPORAL_TASK_QUEUE` env var.
fn task_queue() -> String {
    std::env::var("TEMPORAL_TASK_QUEUE").unwrap_or_else(|_| "fs-worker".to_string())
}

/// Deployment name — overridable via `TEMPORAL_DEPLOYMENT_NAME` env var.
fn deployment_name() -> String {
    std::env::var("TEMPORAL_DEPLOYMENT_NAME").unwrap_or_else(|_| "fs-worker".to_string())
}

/// Build ID embedded at compile time from the `BUILD_ID` env var, falling
/// back to the crate version so there is always a meaningful value.
fn build_id() -> String {
    option_env!("BUILD_ID")
        .unwrap_or(env!("CARGO_PKG_VERSION"))
        .to_string()
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // ── Tracing ───────────────────────────────────────────────────────────
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let host = temporal_host();
    let namespace = temporal_namespace();
    let queue = task_queue();
    let deployment = deployment_name();
    let build = build_id();

    tracing::info!(
        host = %host,
        namespace = %namespace,
        task_queue = %queue,
        deployment = %deployment,
        build_id = %build,
        "Starting fs-worker Temporal activity worker",
    );

    // ── Temporal runtime ──────────────────────────────────────────────────
    let telemetry_options = TelemetryOptions::builder().build();
    let runtime_options = RuntimeOptions::builder()
        .telemetry_options(telemetry_options)
        .build()?;
    let runtime = CoreRuntime::new_assume_tokio(runtime_options)?;

    // ── Temporal client ───────────────────────────────────────────────────
    let connection_options =
        ConnectionOptions::new(Url::from_str(&host)?).build();
    let connection = Connection::connect(connection_options).await?;
    let client = Client::new(
        connection,
        ClientOptions::new(namespace).build(),
    )?;

    // ── Worker ────────────────────────────────────────────────────────────
    let worker_options = WorkerOptions::new(queue)
        .task_types(WorkerTaskTypes::activity_only())
        .deployment_options(WorkerDeploymentOptions {
            version: WorkerDeploymentVersion {
                deployment_name: deployment,
                build_id: build,
            },
            use_worker_versioning: false,
            default_versioning_behavior: None,
        })
        .register_activities(FsWorkerActivities::default())
        .build();

    let mut worker = Worker::new(&runtime, client, worker_options)?;

    tracing::info!("Worker started — waiting for activity tasks");
    worker.run().await?;

    Ok(())
}
