use std::net::SocketAddr;
use std::path::PathBuf;

use clap::Args;
use serde::Deserialize;

use crate::error::{Error, Result};
use crate::net::{TlsClient, TlsResumption};

pub const DEFAULT_INVENTORY: &str = "/etc/bench/hosts.json";
pub const DEFAULT_ENV_FILE: &str = "/etc/bench/bench.env";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ServerKind {
    Stalwart,
    Dovecot,
}

impl ServerKind {
    fn from_target(name: &str) -> Option<Self> {
        hashify::tiny_map!(name.as_bytes(),
            "stalwart" => ServerKind::Stalwart,
            "dovecot" => ServerKind::Dovecot,
            "postfix-dovecot" => ServerKind::Dovecot,
        )
    }

    fn role(self) -> &'static str {
        match self {
            ServerKind::Stalwart => "stalwart",
            ServerKind::Dovecot => "postfix-dovecot",
        }
    }
}

#[derive(Args, Clone, Debug)]
pub struct TargetArgs {
    #[arg(long, help = "Target name: stalwart or dovecot")]
    pub target: String,
    #[arg(long, default_value = DEFAULT_INVENTORY)]
    pub inventory: PathBuf,
    #[arg(long, help = "Server address, overrides the inventory")]
    pub server: Option<String>,
    #[arg(long, default_value = "example.org")]
    pub domain: String,
    #[arg(long, default_value_t = 25)]
    pub smtp_port: u16,
    #[arg(long, default_value_t = 465)]
    pub submission_port: u16,
    #[arg(long, default_value_t = 587)]
    pub submission_starttls_port: u16,
    #[arg(long, default_value_t = 993)]
    pub imap_port: u16,
    #[arg(long, default_value_t = 443)]
    pub https_port: u16,
    #[arg(long, help = "TLS server name (SNI), defaults to mail.<domain>")]
    pub tls_name: Option<String>,
    #[arg(long, help = "Enable TLS session resumption")]
    pub tls_resumption: bool,
}

#[derive(Clone)]
pub struct Target {
    pub name: String,
    pub kind: ServerKind,
    pub smtp: SocketAddr,
    pub submission: SocketAddr,
    pub submission_starttls: SocketAddr,
    pub imap: SocketAddr,
    pub https: SocketAddr,
    pub tls: TlsClient,
    pub domain: String,
}

#[derive(Deserialize)]
struct Inventory {
    hosts: Vec<InventoryHost>,
}

#[derive(Deserialize)]
struct InventoryHost {
    name: String,
    role: String,
    private_ip: String,
}

impl TargetArgs {
    pub async fn resolve(&self) -> Result<Target> {
        let kind = ServerKind::from_target(&self.target)
            .ok_or_else(|| Error::config(format!("unknown target {}", self.target)))?;
        let host = match &self.server {
            Some(server) => server.clone(),
            None => inventory_host(&self.inventory, kind.role())?,
        };
        let resolve = |port: u16| {
            let host = host.clone();
            async move {
                tokio::net::lookup_host((host.as_str(), port))
                    .await?
                    .next()
                    .ok_or_else(|| Error::config(format!("cannot resolve {host}")))
            }
        };
        let tls_name = self
            .tls_name
            .clone()
            .unwrap_or_else(|| format!("mail.{}", self.domain));
        let resumption = if self.tls_resumption {
            TlsResumption::Enabled
        } else {
            TlsResumption::Disabled
        };
        Ok(Target {
            name: self.target.clone(),
            kind,
            smtp: resolve(self.smtp_port).await?,
            submission: resolve(self.submission_port).await?,
            submission_starttls: resolve(self.submission_starttls_port).await?,
            imap: resolve(self.imap_port).await?,
            https: resolve(self.https_port).await?,
            tls: TlsClient::new(&tls_name, resumption)?,
            domain: self.domain.clone(),
        })
    }
}

pub fn inventory_host(path: &std::path::Path, role: &str) -> Result<String> {
    let text = std::fs::read_to_string(path)
        .map_err(|err| Error::config(format!("cannot read inventory {}: {err}", path.display())))?;
    let inventory: Inventory = serde_json::from_str(&text)?;
    inventory
        .hosts
        .into_iter()
        .find(|h| h.role == role || h.name == role)
        .map(|h| h.private_ip)
        .ok_or_else(|| Error::config(format!("no host with role {role} in {}", path.display())))
}

pub fn host_name() -> String {
    std::env::var("BENCH_HOST")
        .ok()
        .or_else(|| {
            std::fs::read_to_string("/etc/hostname")
                .ok()
                .map(|s| s.trim().to_string())
        })
        .or_else(|| std::env::var("HOSTNAME").ok())
        .unwrap_or_else(|| "localhost".into())
}

pub fn env_file_value(path: &std::path::Path, key: &str) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    text.lines().find_map(|line| {
        let (k, v) = line.trim().split_once('=')?;
        (k.trim() == key).then(|| {
            let v = v.trim();
            v.strip_prefix('\'')
                .and_then(|v| v.strip_suffix('\''))
                .or_else(|| v.strip_prefix('"').and_then(|v| v.strip_suffix('"')))
                .unwrap_or(v)
                .to_string()
        })
    })
}
