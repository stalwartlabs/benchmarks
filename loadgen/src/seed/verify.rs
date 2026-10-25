use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use clap::Args;
use serde::Serialize;
use sha2::{Digest, Sha256};
use tokio::sync::Semaphore;

use super::{DatasetArgs, Selection};
use crate::corpus::Corpus;
use crate::dataset::{AccountId, Dataset};
use crate::error::{Error, Result};
use crate::ops::create_folder;
use crate::proto::imap::{Capture, ImapClient, quote};
use crate::rng::Rng;
use crate::seed::fill::folder_count;
use crate::stats::Timer;
use crate::target::{Target, TargetArgs};

const MAX_REPORTED: usize = 200;

#[derive(Args, Debug)]
pub struct VerifyArgs {
    #[command(flatten)]
    pub dataset: DatasetArgs,
    #[command(flatten)]
    pub target: TargetArgs,
    #[command(flatten)]
    pub selection: Selection,
    #[arg(
        long,
        default_value_t = 50,
        help = "Accounts whose message hashes are sampled"
    )]
    pub sample_accounts: usize,
    #[arg(long, default_value_t = 3, help = "Messages hashed per sampled folder")]
    pub sample_messages: u32,
    #[arg(long, default_value_t = 32)]
    pub concurrency: usize,
    #[arg(long)]
    pub out: PathBuf,
}

#[derive(Serialize, Default)]
pub struct VerifyReport {
    pub target: String,
    pub dataset: String,
    pub seed: u64,
    pub accounts: u64,
    pub folders: u64,
    pub messages_expected: u64,
    pub messages_found: u64,
    pub count_mismatches: u64,
    pub hashes_checked: u64,
    pub hash_mismatches: u64,
    pub errors: u64,
    pub details: Vec<String>,
    pub ok: bool,
}

impl VerifyReport {
    fn note(&mut self, line: String) {
        if self.details.len() < MAX_REPORTED {
            self.details.push(line);
        }
    }
}

pub async fn verify(args: VerifyArgs) -> Result<VerifyReport> {
    let target = Arc::new(args.target.resolve().await?);
    let dataset = Arc::new(args.dataset.dataset(&target.domain));
    let corpus = Arc::new(Corpus::new(args.dataset.word_list.as_deref())?);
    let accounts = args.selection.accounts(&dataset)?;
    let stride = (accounts.len() / args.sample_accounts.max(1)).max(1);
    let report = Arc::new(Mutex::new(VerifyReport {
        target: target.name.clone(),
        dataset: format!("{:?}", args.dataset.dataset).to_lowercase(),
        seed: args.dataset.seed,
        ..VerifyReport::default()
    }));
    let semaphore = Arc::new(Semaphore::new(args.concurrency.max(1)));
    let mut handles = Vec::with_capacity(accounts.len());
    for (n, account) in accounts.into_iter().enumerate() {
        let sample = matches!(account, AccountId::Large(_)) || n % stride == 0;
        let permit = semaphore
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| Error::Protocol("semaphore closed".into()))?;
        let (target, dataset, corpus, report) = (
            target.clone(),
            dataset.clone(),
            corpus.clone(),
            report.clone(),
        );
        let messages = if sample { args.sample_messages } else { 0 };
        handles.push(tokio::spawn(async move {
            if let Err(err) =
                verify_account(&target, &dataset, &corpus, account, messages, &report).await
            {
                let mut report = report.lock().unwrap_or_else(|e| e.into_inner());
                report.errors += 1;
                report.note(format!("{}: {err}", dataset.address(account)));
            }
            drop(permit);
        }));
    }
    for handle in handles {
        let _ = handle.await;
    }
    let mut report = std::mem::take(&mut *report.lock().unwrap_or_else(|e| e.into_inner()));
    report.ok = report.count_mismatches == 0 && report.hash_mismatches == 0 && report.errors == 0;
    if let Some(parent) = args.out.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&args.out, serde_json::to_vec_pretty(&report)?)?;
    Ok(report)
}

async fn verify_account(
    target: &Target,
    dataset: &Dataset,
    corpus: &Corpus,
    account: AccountId,
    sample_messages: u32,
    report: &Mutex<VerifyReport>,
) -> Result<()> {
    let mut timer = Timer::start();
    let address = dataset.address(account);
    let mut client = ImapClient::connect_login(
        target.imap,
        &target.tls,
        &address,
        &dataset.password(account),
        &mut timer,
    )
    .await?;
    client.setup().await?;
    let mut rng = Rng::from_parts(&[dataset.seed, dataset.ordinal(account), 0x7665_7269]);
    let mut buf = Vec::with_capacity(64 * 1024);
    for (index, folder) in dataset.folders(account).iter().enumerate() {
        let found = if folder.count == 0 {
            create_folder(&mut client, &folder.name).await?;
            folder_count(&mut client, &folder.name).await?
        } else {
            folder_count(&mut client, &folder.name).await?
        };
        let mut hash_results = Vec::new();
        if sample_messages > 0 && found == folder.count && folder.count > 0 {
            let mut cmd = Vec::with_capacity(64);
            cmd.extend_from_slice(b"EXAMINE ");
            quote(&mut cmd, &client.folder_name(&folder.name));
            client.run_raw(&cmd, "EXAMINE", Capture::None).await?;
            for _ in 0..sample_messages.min(folder.count) {
                let idx = rng.below(u64::from(folder.count)) as u32;
                let summary = client
                    .run_capture(&format!("FETCH {} (BODY.PEEK[])", idx + 1), "FETCH")
                    .await?;
                buf.clear();
                dataset.message(corpus, account, index, folder, idx, &mut buf);
                let expected = Sha256::digest(&buf);
                let matched = summary
                    .literals
                    .first()
                    .is_some_and(|got| Sha256::digest(got) == expected);
                hash_results.push((idx, matched));
            }
            client.run("UNSELECT", "UNSELECT").await?;
        }
        let mut report = report.lock().unwrap_or_else(|e| e.into_inner());
        report.folders += 1;
        report.messages_expected += u64::from(folder.count);
        report.messages_found += u64::from(found);
        if found != folder.count {
            report.count_mismatches += 1;
            report.note(format!(
                "{address} {}: found {found}, expected {}",
                folder.name, folder.count
            ));
        }
        for (idx, matched) in hash_results {
            report.hashes_checked += 1;
            if !matched {
                report.hash_mismatches += 1;
                report.note(format!(
                    "{address} {} message {}: content hash mismatch",
                    folder.name,
                    idx + 1
                ));
            }
        }
    }
    report.lock().unwrap_or_else(|e| e.into_inner()).accounts += 1;
    let _ = client.logout().await;
    Ok(())
}
