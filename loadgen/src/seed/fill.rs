use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use tokio::sync::Semaphore;

use crate::corpus::Corpus;
use crate::dataset::{AccountId, Dataset};
use crate::error::{Error, Result};
use crate::proto::imap::{Capture, ImapClient, quote};
use crate::stats::Timer;
use crate::target::Target;

const BATCH_BYTES: usize = 8 * 1024 * 1024;
const PROGRESS_INTERVAL: Duration = Duration::from_secs(10);
const RETRIES: u32 = 5;

#[derive(Default)]
struct Progress {
    accounts: AtomicU64,
    messages: AtomicU64,
    bytes: AtomicU64,
    failed: AtomicU64,
}

pub async fn fill_mailboxes(
    target: Arc<Target>,
    dataset: Arc<Dataset>,
    corpus: Arc<Corpus>,
    mut accounts: Vec<AccountId>,
    concurrency: usize,
    batch: usize,
) -> Result<()> {
    accounts.sort_unstable_by_key(|a| std::cmp::Reverse(expected_total(&dataset, *a)));
    let total_accounts = accounts.len();
    let total_messages: u64 = accounts.iter().map(|a| expected_total(&dataset, *a)).sum();
    let progress = Arc::new(Progress::default());
    let semaphore = Arc::new(Semaphore::new(concurrency.max(1)));
    let started = Instant::now();
    let reporter = {
        let progress = progress.clone();
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(PROGRESS_INTERVAL);
            ticker.tick().await;
            loop {
                ticker.tick().await;
                let messages = progress.messages.load(Ordering::Relaxed);
                let elapsed = started.elapsed().as_secs_f64();
                eprintln!(
                    "seed: accounts {}/{total_accounts}, messages {messages} appended ({:.0}/s, {:.1} MB/s), up to {total_messages} expected",
                    progress.accounts.load(Ordering::Relaxed),
                    messages as f64 / elapsed,
                    progress.bytes.load(Ordering::Relaxed) as f64 / elapsed / 1e6,
                );
            }
        })
    };
    let mut handles = Vec::with_capacity(accounts.len());
    for account in accounts {
        let permit = semaphore
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| Error::Protocol("semaphore closed".into()))?;
        let target = target.clone();
        let dataset = dataset.clone();
        let corpus = corpus.clone();
        let progress = progress.clone();
        handles.push(tokio::spawn(async move {
            let mut attempt = 0;
            loop {
                match fill_account(&target, &dataset, &corpus, account, batch, &progress).await {
                    Ok(()) => break,
                    Err(err) if attempt < RETRIES => {
                        attempt += 1;
                        eprintln!(
                            "seed {}: {err}, retrying ({attempt}/{RETRIES})",
                            dataset.address(account)
                        );
                        tokio::time::sleep(Duration::from_secs(u64::from(attempt) * 2)).await;
                    }
                    Err(err) => {
                        eprintln!("seed {}: giving up: {err}", dataset.address(account));
                        progress.failed.fetch_add(1, Ordering::Relaxed);
                        break;
                    }
                }
            }
            progress.accounts.fetch_add(1, Ordering::Relaxed);
            drop(permit);
        }));
    }
    for handle in handles {
        let _ = handle.await;
    }
    reporter.abort();
    let failed = progress.failed.load(Ordering::Relaxed);
    eprintln!(
        "seed done in {:.1}s: {} accounts, {} messages appended, {failed} accounts failed",
        started.elapsed().as_secs_f64(),
        progress.accounts.load(Ordering::Relaxed),
        progress.messages.load(Ordering::Relaxed)
    );
    if failed > 0 {
        return Err(Error::Mismatch(format!(
            "{failed} accounts could not be seeded"
        )));
    }
    Ok(())
}

fn expected_total(dataset: &Dataset, account: AccountId) -> u64 {
    dataset
        .folders(account)
        .iter()
        .map(|f| u64::from(f.count))
        .sum()
}

pub async fn folder_count(client: &mut ImapClient, folder: &str) -> Result<u32> {
    let mut cmd = Vec::with_capacity(folder.len() + 32);
    cmd.extend_from_slice(b"STATUS ");
    quote(&mut cmd, &client.folder_name(folder));
    cmd.extend_from_slice(b" (MESSAGES)");
    let summary = client.run_raw(&cmd, "STATUS", Capture::None).await?;
    summary
        .status_messages
        .ok_or_else(|| Error::Protocol(format!("STATUS {folder} without MESSAGES")))
}

async fn fill_account(
    target: &Target,
    dataset: &Dataset,
    corpus: &Corpus,
    account: AccountId,
    batch_size: usize,
    progress: &Progress,
) -> Result<()> {
    let mut timer = Timer::start();
    let mut client = ImapClient::connect_login(
        target.imap,
        &target.tls,
        &dataset.address(account),
        &dataset.password(account),
        &mut timer,
    )
    .await?;
    client.setup().await?;
    let folders = dataset.folders(account);
    let mut batch: Vec<(String, Option<String>, Vec<u8>)> = Vec::with_capacity(batch_size);
    let mut batch_bytes = 0;
    for (index, folder) in folders.iter().enumerate() {
        if folder.count == 0 && folder.name != "INBOX" {
            crate::ops::create_folder(&mut client, &folder.name).await?;
            continue;
        }
        crate::ops::create_folder(&mut client, &folder.name).await?;
        let have = folder_count(&mut client, &folder.name).await?;
        if have > folder.count {
            return Err(Error::Mismatch(format!(
                "{} {} has {have} messages, expected {}",
                dataset.address(account),
                folder.name,
                folder.count
            )));
        }
        for idx in have..folder.count {
            let mut message = Vec::with_capacity(16 * 1024);
            let meta = dataset.message(corpus, account, index, folder, idx, &mut message);
            let mut flags = String::new();
            if meta.seen {
                flags.push_str("\\Seen");
            }
            if meta.flagged {
                if !flags.is_empty() {
                    flags.push(' ');
                }
                flags.push_str("\\Flagged");
            }
            let mut date = String::with_capacity(32);
            meta.date.write_imap(&mut date);
            batch_bytes += message.len();
            batch.push((flags, Some(date), message));
            if batch.len() >= batch_size || batch_bytes >= BATCH_BYTES {
                flush(&mut client, &folder.name, &mut batch, progress).await?;
                batch_bytes = 0;
            }
        }
        flush(&mut client, &folder.name, &mut batch, progress).await?;
        batch_bytes = 0;
    }
    let _ = client.logout().await;
    Ok(())
}

async fn flush(
    client: &mut ImapClient,
    folder: &str,
    batch: &mut Vec<(String, Option<String>, Vec<u8>)>,
    progress: &Progress,
) -> Result<()> {
    if batch.is_empty() {
        return Ok(());
    }
    let bytes: usize = batch.iter().map(|(_, _, m)| m.len()).sum();
    let count = client.append_pipelined(folder, batch).await?;
    progress
        .messages
        .fetch_add(u64::from(count), Ordering::Relaxed);
    progress.bytes.fetch_add(bytes as u64, Ordering::Relaxed);
    batch.clear();
    Ok(())
}
