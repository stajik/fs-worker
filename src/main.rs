mod zfs_service;

use std::net::SocketAddr;

use tonic::transport::Server;
use worker_proto::worker_server::WorkerServer;

pub mod worker_proto {
    tonic::include_proto!("worker");
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let addr: SocketAddr = "0.0.0.0:50051".parse()?;

    println!("Worker gRPC server listening on {addr}");

    Server::builder()
        .add_service(WorkerServer::new(zfs_service::ZfsService::default()))
        .serve(addr)
        .await?;

    Ok(())
}
