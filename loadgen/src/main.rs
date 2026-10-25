mod corpus;
mod dataset;
mod error;
mod load;
mod net;
mod ops;
mod proto;
mod rng;
mod run;
mod scenario;
mod seed;
mod stats;
mod target;

use std::io::Write;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};

use crate::corpus::Corpus;
use crate::dataset::FolderPlan;
use crate::error::{Error, Result};
use crate::run::{RunArgs, write_report};
use crate::scenario::{Profile, list_dir};
use crate::seed::{AccountsArgs, CleanupArgs, DatasetArgs, SeedArgs, VerifyArgs};
use crate::stats::{RunReport, merge_reports};

const EXIT_INVALID_RUN: u8 = 3;
const EXIT_VERIFY_FAILED: u8 = 4;

#[derive(Parser)]
#[command(
    name = "mailbench",
    version,
    about = "Mail server load generator, seeder and delivery probe"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    #[command(about = "List the cells of every scenario file in a directory")]
    Scenarios {
        dir: PathBuf,
        #[arg(long)]
        json: bool,
        #[arg(
            long,
            help = "Profile file that filters cells, overrides fields and assigns groups"
        )]
        profile: Option<PathBuf>,
        #[arg(long, help = "Only list cells of this group (needs --profile)")]
        group: Option<String>,
    },
    #[command(about = "Run one scenario cell against a target")]
    Run(RunArgs),
    #[command(about = "Merge result files from several load hosts")]
    Merge {
        inputs: Vec<PathBuf>,
        #[arg(long)]
        out: PathBuf,
    },
    #[command(about = "Write the account list of a dataset")]
    Accounts(AccountsArgs),
    #[command(about = "Create accounts and fill mailboxes")]
    Seed(SeedArgs),
    #[command(about = "Check message counts and content hashes against the dataset")]
    Verify(VerifyArgs),
    #[command(
        about = "Expunge load-test messages delivered after the seed from every INBOX (restores the seeded INBOX)"
    )]
    Cleanup(CleanupArgs),
    #[command(about = "Run the sink MTA used as relay destination")]
    Sink {
        #[arg(long, default_value = "0.0.0.0:25")]
        listen: SocketAddr,
        #[arg(long, default_value = "sink.example.net")]
        hostname: String,
    },
    #[command(about = "Print one dataset message to stdout")]
    Message {
        #[command(flatten)]
        dataset: DatasetArgs,
        #[arg(long, default_value = "example.org")]
        domain: String,
        #[arg(long, help = "Account local part, such as user0001 or large10k")]
        account: String,
        #[arg(long, default_value = "INBOX")]
        folder: String,
        #[arg(long, default_value_t = 0)]
        index: u32,
    },
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    match runtime.block_on(dispatch(cli.command)) {
        Ok(code) => code,
        Err(err) => {
            eprintln!("mailbench: {err}");
            ExitCode::FAILURE
        }
    }
}

async fn dispatch(command: Command) -> Result<ExitCode> {
    match command {
        Command::Scenarios {
            dir,
            json,
            profile,
            group,
        } => {
            let profile = profile.as_deref().map(Profile::load).transpose()?;
            let files = list_dir(&dir, profile.as_ref())?;
            let listing: Vec<_> = files
                .iter()
                .flat_map(|f| f.listing())
                .filter(|cell| group.is_none() || cell.group == group.as_deref())
                .collect();
            if json {
                println!("{}", serde_json::to_string_pretty(&listing)?);
            } else {
                for cell in &listing {
                    println!(
                        "{}\t{}\t{}\t{}",
                        cell.id,
                        cell.mode.name(),
                        cell.file,
                        cell.title
                    );
                }
            }
            Ok(ExitCode::SUCCESS)
        }
        Command::Run(args) => {
            let report = run::run(args).await?;
            print_summary(&report);
            Ok(if report.valid {
                ExitCode::SUCCESS
            } else {
                ExitCode::from(EXIT_INVALID_RUN)
            })
        }
        Command::Merge { inputs, out } => {
            let mut reports = Vec::with_capacity(inputs.len());
            for input in &inputs {
                let text = std::fs::read(input)?;
                reports.push(serde_json::from_slice::<RunReport>(&text)?);
            }
            let merged = merge_reports(reports)?;
            write_report(&out, &merged)?;
            print_summary(&merged);
            Ok(if merged.valid {
                ExitCode::SUCCESS
            } else {
                ExitCode::from(EXIT_INVALID_RUN)
            })
        }
        Command::Accounts(args) => {
            let count = seed::write_accounts(&args)?;
            eprintln!("wrote {count} accounts to {}", args.out.display());
            Ok(ExitCode::SUCCESS)
        }
        Command::Seed(args) => {
            seed::seed(args).await?;
            Ok(ExitCode::SUCCESS)
        }
        Command::Verify(args) => {
            let report = seed::verify(args).await?;
            eprintln!(
                "verify: {} accounts, {} folders, {}/{} messages, {} count mismatches, {}/{} hash mismatches, {} errors",
                report.accounts,
                report.folders,
                report.messages_found,
                report.messages_expected,
                report.count_mismatches,
                report.hash_mismatches,
                report.hashes_checked,
                report.errors
            );
            Ok(if report.ok {
                ExitCode::SUCCESS
            } else {
                ExitCode::from(EXIT_VERIFY_FAILED)
            })
        }
        Command::Cleanup(args) => {
            seed::cleanup(args).await?;
            Ok(ExitCode::SUCCESS)
        }
        Command::Sink { listen, hostname } => {
            proto::sink::run(listen, &hostname).await?;
            Ok(ExitCode::SUCCESS)
        }
        Command::Message {
            dataset,
            domain,
            account,
            folder,
            index,
        } => {
            let corpus = Corpus::new(dataset.word_list.as_deref())?;
            let ds = dataset.dataset(&domain);
            let id = ds
                .accounts()
                .find(|a| {
                    let mut name = String::new();
                    ds.write_local_part(*a, &mut name);
                    name == account
                })
                .ok_or_else(|| Error::config(format!("no account {account}")))?;
            let folders = ds.folders(id);
            let (position, plan): (usize, &FolderPlan) = folders
                .iter()
                .enumerate()
                .find(|(_, f)| f.name == folder)
                .ok_or_else(|| Error::config(format!("no folder {folder}")))?;
            if index >= plan.count {
                return Err(Error::config(format!(
                    "{folder} has {} messages",
                    plan.count
                )));
            }
            let mut out = Vec::new();
            ds.message(&corpus, id, position, plan, index, &mut out);
            std::io::stdout().write_all(&out)?;
            Ok(ExitCode::SUCCESS)
        }
    }
}

fn print_summary(report: &RunReport) {
    for step in &report.steps {
        let rate = step
            .target_rate
            .map(|r| format!(" rate={r}/s"))
            .unwrap_or_default();
        eprintln!(
            "{} {} step {}{rate} valid={} slo={:?} cpu={:?}",
            report.cell,
            report.target,
            step.index,
            step.valid,
            step.slo_met,
            step.generator.cpu_mean_pct
        );
        for reason in &step.invalid_reasons {
            eprintln!("  invalid: {reason}");
        }
        for (label, op) in &step.ops {
            eprintln!(
                "  {label}: n={} err={} {:.1}/s p50={}us p95={}us p99={}us max={}us",
                op.count,
                op.errors,
                op.throughput,
                op.latency.p50,
                op.latency.p95,
                op.latency.p99,
                op.latency.max
            );
            for sample in &op.error_samples {
                eprintln!("    error: {sample}");
            }
        }
    }
}
