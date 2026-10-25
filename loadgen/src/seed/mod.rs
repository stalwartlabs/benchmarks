mod cleanup;
mod fill;
mod stalwart;
mod verify;

use std::io::Write;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use clap::{Args, ValueEnum};

pub use cleanup::{CleanupArgs, cleanup};
pub use fill::fill_mailboxes;
pub use verify::{VerifyArgs, verify};

use crate::dataset::{AccountId, DEFAULT_SEED, Dataset, DatasetName};
use crate::error::{Error, Result};
use crate::run::parse_shard;
use crate::target::{DEFAULT_ENV_FILE, ServerKind, Target, TargetArgs, env_file_value};
use stalwart::{MAX_BATCH, StalwartApi};

#[derive(Args, Debug, Clone)]
pub struct DatasetArgs {
    #[arg(long, value_enum)]
    pub dataset: DatasetName,
    #[arg(long, default_value_t = DEFAULT_SEED)]
    pub seed: u64,
    #[arg(long, help = "Word list file (one word per line, most frequent first)")]
    pub word_list: Option<PathBuf>,
}

impl DatasetArgs {
    pub fn dataset(&self, domain: &str) -> Dataset {
        Dataset::new(self.dataset, self.seed, domain)
    }
}

#[derive(Args, Debug, Clone)]
pub struct Selection {
    #[arg(
        long,
        default_value = "0/1",
        help = "Shard of the accounts, as I/N (0-based)"
    )]
    pub shard: String,
    #[arg(
        long,
        help = "Regular users to include, 1-based inclusive range such as 1-5000"
    )]
    pub users: Option<String>,
    #[arg(long, help = "Leave out the large-mailbox accounts")]
    pub skip_large: bool,
    #[arg(long, help = "Only the large-mailbox accounts")]
    pub large_only: bool,
}

impl Selection {
    pub fn accounts(&self, dataset: &Dataset) -> Result<Vec<AccountId>> {
        let (shard, shards) = parse_shard(&self.shard)?;
        let (lo, hi) = match &self.users {
            Some(range) => {
                let (lo, hi) = range.split_once('-').unwrap_or((range, range));
                let lo: u32 = lo
                    .trim()
                    .parse()
                    .map_err(|_| Error::config(format!("invalid range {range}")))?;
                let hi: u32 = hi
                    .trim()
                    .parse()
                    .map_err(|_| Error::config(format!("invalid range {range}")))?;
                (lo.max(1) - 1, hi)
            }
            None => (0, dataset.users()),
        };
        Ok(dataset
            .accounts()
            .filter(|account| match account {
                AccountId::Regular(i) => !self.large_only && *i >= lo && *i < hi,
                AccountId::Large(_) => !self.skip_large,
            })
            .filter(|account| dataset.ordinal(*account) % u64::from(shards) == u64::from(shard))
            .collect())
    }
}

#[derive(Clone, Copy, Debug, ValueEnum)]
pub enum AccountFormat {
    Tsv,
    DovecotPasswd,
    PostfixVmailbox,
}

#[derive(Args, Debug)]
pub struct AccountsArgs {
    #[command(flatten)]
    pub dataset: DatasetArgs,
    #[arg(long, default_value = "example.org")]
    pub domain: String,
    #[arg(long, value_enum, default_value = "tsv")]
    pub format: AccountFormat,
    #[arg(long)]
    pub out: PathBuf,
}

pub fn write_accounts(args: &AccountsArgs) -> Result<u64> {
    let dataset = args.dataset.dataset(&args.domain);
    let accounts: Vec<AccountId> = dataset.accounts().collect();
    let hashes = hash_all(&dataset, &accounts)?;
    let tmp = args.out.with_extension("tmp");
    let mut out = std::io::BufWriter::new(std::fs::File::create(&tmp)?);
    for (account, hash) in accounts.iter().zip(&hashes) {
        let address = dataset.address(*account);
        match args.format {
            AccountFormat::Tsv => {
                writeln!(out, "{address}\t{}\t{hash}\t0", dataset.password(*account))?
            }
            AccountFormat::DovecotPasswd => {
                writeln!(out, "{address}:{{SHA512-CRYPT}}{hash}::::::")?
            }
            AccountFormat::PostfixVmailbox => writeln!(out, "{address} {address}")?,
        }
    }
    out.flush()?;
    drop(out);
    std::fs::rename(&tmp, &args.out)?;
    Ok(accounts.len() as u64)
}

fn hash_all(dataset: &Dataset, accounts: &[AccountId]) -> Result<Vec<String>> {
    let threads = std::thread::available_parallelism().map_or(4, |n| n.get());
    let chunk = accounts.len().div_ceil(threads).max(1);
    std::thread::scope(|scope| {
        let handles: Vec<_> = accounts
            .chunks(chunk)
            .map(|part| {
                scope.spawn(move || {
                    part.iter()
                        .map(|a| dataset.password_hash(*a))
                        .collect::<Result<Vec<_>>>()
                })
            })
            .collect();
        let mut out = Vec::with_capacity(accounts.len());
        for handle in handles {
            out.extend(
                handle
                    .join()
                    .map_err(|_| Error::config("hash thread panicked"))??,
            );
        }
        Ok(out)
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, ValueEnum)]
pub enum SeedStep {
    Accounts,
    Mailboxes,
    All,
}

#[derive(Args, Debug)]
pub struct SeedArgs {
    #[command(flatten)]
    pub dataset: DatasetArgs,
    #[command(flatten)]
    pub target: TargetArgs,
    #[command(flatten)]
    pub selection: Selection,
    #[arg(long, value_enum, default_value = "all")]
    pub step: SeedStep,
    #[arg(long, default_value_t = 32, help = "Accounts filled in parallel")]
    pub concurrency: usize,
    #[arg(long, default_value_t = 50, help = "APPENDs pipelined per batch")]
    pub batch: usize,
    #[arg(long, default_value = "admin@example.org")]
    pub admin_user: String,
    #[arg(
        long,
        help = "Admin password; defaults to $BENCH_ADMIN_PASSWORD or the env file"
    )]
    pub admin_password: Option<String>,
    #[arg(long, default_value = DEFAULT_ENV_FILE)]
    pub env_file: PathBuf,
}

impl SeedArgs {
    fn admin_password(&self) -> Result<String> {
        self.admin_password
            .clone()
            .or_else(|| std::env::var("BENCH_ADMIN_PASSWORD").ok())
            .or_else(|| env_file_value(&self.env_file, "BENCH_ADMIN_PASSWORD"))
            .ok_or_else(|| {
                Error::config(
                    "admin password missing: pass --admin-password or set BENCH_ADMIN_PASSWORD",
                )
            })
    }
}

pub async fn seed(args: SeedArgs) -> Result<()> {
    let target = Arc::new(args.target.resolve().await?);
    let dataset = args.dataset.dataset(&target.domain);
    let accounts = args.selection.accounts(&dataset)?;
    if matches!(args.step, SeedStep::Accounts | SeedStep::All) {
        match target.kind {
            ServerKind::Stalwart => {
                create_stalwart_accounts(&args, &target, &dataset, &accounts).await?
            }
            ServerKind::Dovecot => eprintln!(
                "dovecot: accounts come from the passwd-file (mailbench accounts + ctl.sh accounts), nothing to create"
            ),
        }
    }
    if matches!(args.step, SeedStep::Mailboxes | SeedStep::All) {
        let corpus = crate::corpus::Corpus::new(args.dataset.word_list.as_deref())?;
        fill_mailboxes(
            target,
            Arc::new(dataset),
            Arc::new(corpus),
            accounts,
            args.concurrency,
            args.batch,
        )
        .await?;
    }
    Ok(())
}

async fn create_stalwart_accounts(
    args: &SeedArgs,
    target: &Target,
    dataset: &Dataset,
    accounts: &[AccountId],
) -> Result<()> {
    let started = Instant::now();
    let mut api = StalwartApi::new(target, &args.admin_user, &args.admin_password()?);
    let domain_id = api.domain_id(&dataset.domain).await?;
    let hashes = hash_all(dataset, accounts)?;
    let mut created = 0;
    let mut existed = 0;
    let mut batch = Vec::with_capacity(MAX_BATCH);
    let mut name = String::with_capacity(32);
    for (chunk_accounts, chunk_hashes) in accounts.chunks(MAX_BATCH).zip(hashes.chunks(MAX_BATCH)) {
        batch.clear();
        for (account, hash) in chunk_accounts.iter().zip(chunk_hashes) {
            name.clear();
            dataset.write_local_part(*account, &mut name);
            batch.push((name.clone(), hash.clone()));
        }
        let outcome = api.create_accounts(&domain_id, &batch).await?;
        if outcome.failed > 0 {
            return Err(Error::Api(format!(
                "{} accounts failed: {}",
                outcome.failed,
                outcome.first_error.unwrap_or_default()
            )));
        }
        created += outcome.created;
        existed += outcome.existed;
        eprintln!(
            "accounts: {created} created, {existed} existed, {}/{} done",
            created + existed,
            accounts.len()
        );
    }
    let total = api.count_accounts().await?;
    eprintln!(
        "accounts done in {:.1}s: {created} created, {existed} already existed, server reports {total} user accounts",
        started.elapsed().as_secs_f64()
    );
    Ok(())
}
