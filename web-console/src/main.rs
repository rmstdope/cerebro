use std::{env, net::SocketAddr, path::PathBuf, sync::Arc};

use cerebro_tui::{Programs, ReaderPaths, RealCommands, SupervisionMode};
use cerebro_web::ReadOnlyService;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let address = env::var("CEREBRO_WEB_ADDRESS")
        .unwrap_or_else(|_| "127.0.0.1:7171".to_string())
        .parse::<SocketAddr>()?;
    let consumer_root = env::current_dir()?;
    let shared_root = env::var_os("CEREBRO_SHARED_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| consumer_root.clone());
    let assets_dir = shared_root.join("web-console/ui/dist");
    let service = ReadOnlyService::new(
        ReaderPaths {
            scripts_dir: shared_root.join(".claude/cerebro/scripts"),
            consumer_root,
            shared_root,
        },
        Programs::default(),
        Arc::new(RealCommands),
        SupervisionMode::ReadOnly(cerebro_tui::ReadOnlyReason::NotOwned),
        assets_dir,
    );
    service.validate_listener_address(address)?;

    let listener = tokio::net::TcpListener::bind(address).await?;
    axum::serve(listener, service.router()).await?;
    Ok(())
}
