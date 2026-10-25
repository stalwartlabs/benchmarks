use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use clap::Args;

use crate::corpus::Corpus;
use crate::dataset::{DEFAULT_SEED, Dataset, DatasetName};
use crate::error::{Error, Result};
use crate::load::{CpuMonitor, Window, cpu_window, run_closed, run_open};
use crate::ops::{Ctx, Shared, supports_open_loop};
use crate::rng::mix_all;
use crate::scenario::{Cell, Dur, LoadSpec, OpSpec, Profile, ScenarioFile};
use crate::stats::report::{CpuWindow, LatencyStats};
use crate::stats::{Recorder, RunReport, SCHEMA, Slo, StepReport, Validity, micros};
use crate::target::{TargetArgs, host_name};

const RTT_SAMPLES: usize = 20;
const SMOKE_SAMPLES: u64 = 50;
const SMOKE_WARMUP: Duration = Duration::from_secs(2);
const SMOKE_STEP: Duration = Duration::from_secs(5);
const SMOKE_MAX_DURATION: Duration = Duration::from_secs(120);
const SMOKE_LADDER_STEPS: usize = 2;

#[derive(Args, Debug)]
pub struct RunArgs {
    #[arg(long)]
    pub scenario: PathBuf,
    #[arg(long)]
    pub cell: String,
    #[command(flatten)]
    pub target: TargetArgs,
    #[arg(
        long,
        help = "Shard of the load, as I/N (0-based)",
        default_value = "0/1"
    )]
    pub shard: String,
    #[arg(long, help = "Wall clock start time in Unix milliseconds")]
    pub start_at: Option<u64>,
    #[arg(long)]
    pub out: PathBuf,
    #[arg(long, default_value_t = DEFAULT_SEED)]
    pub seed: u64,
    #[arg(long, help = "Word list file (one word per line, most frequent first)")]
    pub word_list: Option<PathBuf>,
    #[arg(
        long,
        default_value_t = 0,
        help = "UDP port for sink notifications (0 = any)"
    )]
    pub sink_port: u16,
    #[arg(
        long,
        help = "Variant name recorded in the result (for example fsync-always)"
    )]
    pub variant: Option<String>,
    #[arg(long, help = "Shrink samples and durations for a smoke test")]
    pub smoke: bool,
    #[arg(
        long,
        value_enum,
        help = "Override the dataset of the cell (for example tiny for smoke tests)"
    )]
    pub dataset: Option<DatasetName>,
    #[arg(long, help = "Override the closed-loop sample target")]
    pub samples: Option<u64>,
    #[arg(
        long,
        help = "Scenario profile applied to the cell (same file as given to `scenarios`)"
    )]
    pub profile: Option<PathBuf>,
}

pub fn parse_shard(text: &str) -> Result<(u32, u32)> {
    let (i, n) = text
        .split_once('/')
        .ok_or_else(|| Error::config(format!("invalid shard {text}, expected I/N")))?;
    let i: u32 = i
        .parse()
        .map_err(|_| Error::config(format!("invalid shard {text}")))?;
    let n: u32 = n
        .parse()
        .map_err(|_| Error::config(format!("invalid shard {text}")))?;
    if n == 0 || i >= n {
        return Err(Error::config(format!("invalid shard {text}")));
    }
    Ok((i, n))
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

fn apply_smoke(cell: &mut Cell) {
    match &mut cell.load {
        LoadSpec::Closed(spec) => {
            spec.samples = spec.samples.min(SMOKE_SAMPLES);
            spec.warmup = Dur(SMOKE_WARMUP);
            spec.max_duration = Dur(spec.max_duration.0.min(SMOKE_MAX_DURATION));
        }
        LoadSpec::Open(spec) => {
            spec.warmup = Dur(SMOKE_WARMUP);
            spec.step_warmup = Dur(Duration::ZERO);
            spec.step_duration = Dur(SMOKE_STEP);
            let mut rates = spec.rate_list();
            rates.truncate(SMOKE_LADDER_STEPS);
            spec.rates = rates;
            spec.ladder = None;
        }
    }
}

fn validate(cell: &Cell) -> Result<()> {
    if let LoadSpec::Open(_) = cell.load {
        if !supports_open_loop(&cell.op) {
            return Err(Error::config(
                "this operation only supports the closed loop model",
            ));
        }
        if let OpSpec::Smtp { probe, .. } = cell.op
            && probe.is_imap()
        {
            return Err(Error::config(
                "the IMAP delivery probe needs the closed loop model",
            ));
        }
    }
    Ok(())
}

async fn measure_rtt(addr: std::net::SocketAddr) -> Option<LatencyStats> {
    let mut hist = crate::stats::recorder_histogram().ok()?;
    for _ in 0..RTT_SAMPLES {
        let started = Instant::now();
        if let Ok(Ok(stream)) =
            tokio::time::timeout(Duration::from_secs(5), tokio::net::TcpStream::connect(addr)).await
        {
            hist.saturating_record(micros(started.elapsed()).max(1));
            drop(stream);
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    (!hist.is_empty()).then(|| LatencyStats::from_histogram(&hist))
}

pub async fn run(args: RunArgs) -> Result<RunReport> {
    let profile = args.profile.as_deref().map(Profile::load).transpose()?;
    let file = ScenarioFile::load(&args.scenario, profile.as_ref())?;
    let mut cell = file.cell(&args.cell)?.clone();
    if args.smoke {
        apply_smoke(&mut cell);
    }
    if let Some(dataset) = args.dataset {
        cell.dataset = dataset;
    }
    if let (Some(samples), LoadSpec::Closed(spec)) = (args.samples, &mut cell.load) {
        spec.samples = samples;
    }
    validate(&cell)?;
    let shard = parse_shard(&args.shard)?;
    let target = Arc::new(args.target.resolve().await?);
    if !cell.targets.iter().any(|t| *t == target.name) {
        eprintln!(
            "warning: target {} is not listed in cell {}",
            target.name, cell.id
        );
    }
    let dataset = Dataset::new(cell.dataset, args.seed, &target.domain);
    let corpus = Corpus::new(args.word_list.as_deref())?;
    let host = host_name();
    let nonce = mix_all(&[now_ms(), u64::from(std::process::id()), shard.0.into()]);
    let ctx = Arc::new(
        Ctx::new(
            target.clone(),
            dataset,
            corpus,
            cell.clone(),
            shard,
            nonce,
            args.sink_port,
        )
        .await?,
    );
    let rtt_addr = match cell.op {
        OpSpec::Smtp { .. } => target.smtp,
        _ => target.imap,
    };
    let rtt = measure_rtt(rtt_addr).await;

    if let Some(start_at) = args.start_at {
        let now = now_ms();
        if start_at > now {
            tokio::time::sleep(Duration::from_millis(start_at - now)).await;
        }
    }

    let steps = match &cell.load {
        LoadSpec::Closed(_) => 1,
        LoadSpec::Open(spec) => spec.rate_list().len(),
    };
    let (primary, target_samples) = match &cell.load {
        LoadSpec::Closed(spec) => (ctx.primary_label(), spec.samples),
        LoadSpec::Open(_) => (ctx.primary_label(), u64::MAX),
    };
    let shared = Arc::new(Shared::new(
        Recorder::new(steps, Validity::LATE_THRESHOLD_US)?,
        primary,
        target_samples,
    ));
    let started_at_ms = now_ms();
    let monitor = CpuMonitor::start();
    let windows: Vec<Window> = match &cell.load {
        LoadSpec::Closed(spec) => run_closed(ctx.clone(), spec, shared.clone()).await?,
        LoadSpec::Open(spec) => {
            run_open(
                ctx.clone(),
                spec,
                shared.clone(),
                shard.1,
                cell.slo.as_ref(),
            )
            .await?
        }
    };
    let cpu = monitor.finish().await;
    let finished_at_ms = now_ms();

    let recorder = shared.recorder.lock().unwrap_or_else(|e| e.into_inner());
    let mut step_reports = Vec::with_capacity(windows.len());
    for (index, (window, stats)) in windows.iter().zip(&recorder.steps).enumerate() {
        let cpu = if cpu.is_empty() {
            CpuWindow {
                mean: None,
                max: None,
            }
        } else {
            cpu_window(&cpu, window.start, window.end)
        };
        step_reports.push(StepReport::build(
            index,
            stats,
            window.seconds(),
            window.rate,
            cpu,
        )?);
    }
    drop(recorder);

    let mut report = RunReport {
        schema: SCHEMA.to_string(),
        scenario: cell.scenario.clone(),
        cell: cell.id.clone(),
        family: cell.family.clone(),
        mode: cell.mode.name().to_string(),
        target: target.name.clone(),
        variant: args.variant.clone(),
        profile: profile.as_ref().map(|p| p.id.clone()),
        hosts: vec![host],
        shards: vec![args.shard.clone()],
        dataset: format!("{:?}", cell.dataset).to_lowercase(),
        seed: args.seed,
        started_at_ms,
        finished_at_ms,
        rtt_us: rtt,
        load: serde_json::to_value(&cell.load)?,
        slo: cell.slo.as_ref().map(|slo| Slo {
            p99_us: micros(slo.p99.0),
            max_error_rate: slo.max_error_rate,
            labels: slo.labels.clone(),
        }),
        steps: step_reports,
        valid: true,
        best_step: None,
        best_rate: None,
    };
    report.finalize();
    write_report(&args.out, &report)?;
    Ok(report)
}

pub fn write_report(path: &Path, report: &RunReport) -> Result<()> {
    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
    {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(report)?)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}
