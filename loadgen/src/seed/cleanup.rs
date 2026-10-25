use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use clap::Args;
use memchr::memmem;
use tokio::sync::Semaphore;

use super::{DatasetArgs, Selection};
use crate::dataset::{AccountId, Dataset};
use crate::error::{Error, Result};
use crate::proto::imap::ImapClient;
use crate::stats::Timer;
use crate::target::{Target, TargetArgs};

const LOADGEN_MARKER: &[u8] = b"@loadgen.";

#[derive(Args, Debug)]
pub struct CleanupArgs {
    #[command(flatten)]
    pub dataset: DatasetArgs,
    #[command(flatten)]
    pub target: TargetArgs,
    #[command(flatten)]
    pub selection: Selection,
    #[arg(long, default_value_t = 32, help = "Accounts cleaned in parallel")]
    pub concurrency: usize,
}

#[derive(Default)]
struct Totals {
    accounts: AtomicU64,
    cleaned: AtomicU64,
    expunged: AtomicU64,
    failed: AtomicU64,
}

pub async fn cleanup(args: CleanupArgs) -> Result<()> {
    let target = Arc::new(args.target.resolve().await?);
    let dataset = Arc::new(args.dataset.dataset(&target.domain));
    let accounts = args.selection.accounts(&dataset)?;
    let totals = Arc::new(Totals::default());
    let semaphore = Arc::new(Semaphore::new(args.concurrency.max(1)));
    let started = Instant::now();
    let mut handles = Vec::with_capacity(accounts.len());
    for account in accounts {
        let permit = semaphore
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| Error::Protocol("semaphore closed".into()))?;
        let (target, dataset, totals) = (target.clone(), dataset.clone(), totals.clone());
        handles.push(tokio::spawn(async move {
            match clean_account(&target, &dataset, account).await {
                Ok(0) => {}
                Ok(expunged) => {
                    totals.cleaned.fetch_add(1, Ordering::Relaxed);
                    totals.expunged.fetch_add(expunged, Ordering::Relaxed);
                }
                Err(err) => {
                    eprintln!("cleanup {}: {err}", dataset.address(account));
                    totals.failed.fetch_add(1, Ordering::Relaxed);
                }
            }
            totals.accounts.fetch_add(1, Ordering::Relaxed);
            drop(permit);
        }));
    }
    for handle in handles {
        let _ = handle.await;
    }
    let failed = totals.failed.load(Ordering::Relaxed);
    eprintln!(
        "cleanup done in {:.1}s: {} accounts checked, {} cleaned, {} messages expunged, {failed} failed",
        started.elapsed().as_secs_f64(),
        totals.accounts.load(Ordering::Relaxed),
        totals.cleaned.load(Ordering::Relaxed),
        totals.expunged.load(Ordering::Relaxed),
    );
    if failed > 0 {
        return Err(Error::Mismatch(format!(
            "{failed} accounts could not be cleaned"
        )));
    }
    Ok(())
}

async fn clean_account(target: &Target, dataset: &Dataset, account: AccountId) -> Result<u64> {
    let seeded = dataset.inbox_size(account);
    let mut timer = Timer::start();
    let mut client = ImapClient::connect_login(
        target.imap,
        &target.tls,
        &dataset.address(account),
        &dataset.password(account),
        &mut timer,
    )
    .await?;
    let exists = client
        .run("SELECT INBOX", "SELECT")
        .await?
        .exists
        .unwrap_or(0);
    if exists <= seeded {
        let _ = client.logout().await;
        return Ok(0);
    }
    for seq in [seeded + 1, exists] {
        let header = client
            .run_capture(
                &format!("FETCH {seq} (BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])"),
                "FETCH",
            )
            .await?;
        let is_loadgen = header
            .literals
            .first()
            .is_some_and(|h| memmem::find(h, LOADGEN_MARKER).is_some());
        if !is_loadgen {
            return Err(Error::Mismatch(format!(
                "INBOX message {seq} of {exists} is not a load-test message (dataset has {seeded}); not expunging"
            )));
        }
    }
    let range = format!("{}:*", seeded + 1);
    client
        .run(&format!("STORE {range} +FLAGS.SILENT (\\Deleted)"), "STORE")
        .await?;
    client.run("EXPUNGE", "EXPUNGE").await?;
    client.run("UNSELECT", "UNSELECT").await?;
    let remaining = client
        .run("SELECT INBOX", "SELECT")
        .await?
        .exists
        .ok_or_else(|| Error::Protocol("SELECT without EXISTS".into()))?;
    let _ = client.logout().await;
    if remaining != seeded {
        return Err(Error::Mismatch(format!(
            "INBOX has {remaining} messages after cleanup, dataset has {seeded}"
        )));
    }
    Ok(u64::from(exists - seeded))
}
