mod imap;
mod mixed;
mod probe;
mod smtp;
mod templates;

use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use crate::corpus::Corpus;
use crate::dataset::{AccountId, Dataset};
use crate::error::{Error, Result};
use crate::proto::imap::ImapClient;
use crate::rng::Rng;
use crate::scenario::{Cell, LoadSpec, OpSpec, SizeSpec, SmtpProbe, UserSet, UserSpec};
use crate::stats::{Event, PhaseTimes, Recorder, Sample, Timer};
use crate::target::Target;

pub use imap::create_folder;
pub use probe::{IdleProbe, ProbeMode, SinkProbe, local_ip_towards};
pub use templates::{Headers, Templates};

const PROBE_READY_TIMEOUT: Duration = Duration::from_secs(60);
const STREAM_MEASURE: u64 = 0x6d65_6173;

pub struct Shared {
    pub recorder: Mutex<Recorder>,
    pub stop: AtomicBool,
    pub primary: &'static str,
    pub target_samples: u64,
}

impl Shared {
    pub fn new(recorder: Recorder, primary: &'static str, target_samples: u64) -> Self {
        Shared {
            recorder: Mutex::new(recorder),
            stop: AtomicBool::new(false),
            primary,
            target_samples,
        }
    }

    pub fn record(&self, event: Event) {
        let mut recorder = self.recorder.lock().unwrap_or_else(|e| e.into_inner());
        let check = match &event {
            Event::Sample(sample) if sample.label == self.primary => Some(sample.step),
            _ => None,
        };
        recorder.record(event);
        if let Some(step) = check
            && recorder.count(step, self.primary) >= self.target_samples
        {
            self.stop.store(true, Ordering::Relaxed);
        }
    }

    pub fn stopped(&self) -> bool {
        self.stop.load(Ordering::Relaxed)
    }
}

#[derive(Clone, Copy)]
pub struct Emitter<'a> {
    shared: &'a Shared,
    step: Option<u16>,
    alias: Option<&'static str>,
}

impl<'a> Emitter<'a> {
    pub fn new(shared: &'a Shared, step: Option<u16>) -> Self {
        Emitter {
            shared,
            step,
            alias: None,
        }
    }

    pub fn with_alias(self, alias: &'static str) -> Self {
        Emitter {
            alias: Some(alias),
            ..self
        }
    }

    pub fn sample(&self, label: &'static str, timer: &Timer, items: Option<u64>) {
        self.sample_us(label, timer.total_us(), timer.phases, items);
    }

    pub fn sample_us(
        &self,
        label: &'static str,
        total_us: u64,
        phases: PhaseTimes,
        items: Option<u64>,
    ) {
        if let Some(step) = self.step {
            self.shared.record(Event::Sample(Sample {
                label,
                step,
                total_us,
                phases,
                items,
            }));
            if let Some(alias) = self.alias.filter(|_| label == self.shared.primary) {
                self.shared.record(Event::Sample(Sample {
                    label: alias,
                    step,
                    total_us,
                    phases,
                    items,
                }));
            }
        }
    }

    #[cold]
    pub fn error(&self, label: &'static str, err: &Error) {
        if let Some(step) = self.step {
            self.shared.record(Event::Error {
                label,
                step,
                kind: err.kind(),
                message: err.to_string(),
            });
        }
    }
}

pub struct Ctx {
    pub target: Arc<Target>,
    pub dataset: Dataset,
    pub corpus: Corpus,
    pub cell: Cell,
    pub users: Arc<[AccountId]>,
    pub templates: Option<Templates>,
    pub nonce: u64,
    pub workload_seed: u64,
    counter: AtomicU64,
    pub sink: Option<SinkProbe>,
    pub search_label: &'static str,
    pub ehlo: String,
    pub timeout: Duration,
}

impl Ctx {
    pub async fn new(
        target: Arc<Target>,
        dataset: Dataset,
        corpus: Corpus,
        cell: Cell,
        shard: (u32, u32),
        nonce: u64,
        sink_port: u16,
    ) -> Result<Self> {
        let users: Arc<[AccountId]> = select_users(&dataset, &cell.users, shard)?.into();
        if let (
            OpSpec::Smtp {
                probe, recipients, ..
            },
            LoadSpec::Closed(load),
        ) = (&cell.op, &cell.load)
            && probe.is_imap()
        {
            let needed = load.sessions as usize * *recipients as usize;
            if users.len() < needed {
                return Err(Error::config(format!(
                    "the delivery probe needs {needed} distinct recipients ({} sessions x {recipients}), the selection has {}",
                    load.sessions,
                    users.len()
                )));
            }
        }
        let templates = match &cell.op {
            OpSpec::Smtp { size, .. } | OpSpec::ImapAppend { size, .. } => {
                Some(Templates::new(&corpus, *size))
            }
            OpSpec::ImapExpunge { .. } => Some(Templates::new(&corpus, SizeSpec::Mix)),
            _ => None,
        };
        let sink = match &cell.op {
            OpSpec::Smtp {
                probe: SmtpProbe::Sink,
                ..
            } => {
                let local = local_ip_towards(target.smtp).await?;
                Some(SinkProbe::start(local, sink_port).await?)
            }
            _ => None,
        };
        let search_label: &'static str = match &cell.op {
            OpSpec::ImapSearch { label, .. } => Box::leak(label.clone().into_boxed_str()),
            _ => "imap.search",
        };
        let ehlo = format!("loadgen.{}", target.domain);
        let cell_hash = cell
            .id
            .bytes()
            .fold(0u64, |acc, b| crate::rng::mix64(acc ^ u64::from(b)));
        let workload_seed = crate::rng::mix_all(&[dataset.seed, cell_hash, u64::from(shard.0)]);
        Ok(Ctx {
            timeout: cell.timeout.0,
            target,
            dataset,
            corpus,
            cell,
            users,
            templates,
            nonce,
            workload_seed,
            counter: AtomicU64::new(0),
            sink,
            search_label,
            ehlo,
        })
    }

    pub fn next_id(&self) -> u64 {
        self.counter.fetch_add(1, Ordering::Relaxed)
    }

    pub fn primary_label(&self) -> &'static str {
        primary_label(&self.cell.op, self.search_label)
    }

    pub fn worker_users(&self, index: usize, workers: usize) -> Arc<[AccountId]> {
        if self.users.len() >= workers && workers > 1 {
            self.users
                .iter()
                .skip(index)
                .step_by(workers)
                .copied()
                .collect()
        } else {
            self.users.clone()
        }
    }
}

pub fn primary_label(op: &OpSpec, search_label: &'static str) -> &'static str {
    match op {
        OpSpec::Smtp { .. } => "smtp",
        OpSpec::ImapLogin => "imap.login",
        OpSpec::ImapList { .. } => "imap.list",
        OpSpec::ImapSelect {
            qresync_changes, ..
        } => {
            if *qresync_changes > 0 {
                "imap.select_qresync"
            } else {
                "imap.select"
            }
        }
        OpSpec::ImapFetch { .. } => "imap.fetch",
        OpSpec::ImapSearch { .. } => search_label,
        OpSpec::ImapSort { thread: true, .. } => "imap.thread",
        OpSpec::ImapSort { .. } => "imap.sort",
        OpSpec::ImapStore { .. } => "imap.store",
        OpSpec::ImapCopy {
            mode: crate::scenario::CopyMode::Copy,
            ..
        } => "imap.copy",
        OpSpec::ImapCopy { .. } => "imap.move",
        OpSpec::ImapExpunge { uid: true, .. } => "imap.uid_expunge",
        OpSpec::ImapExpunge { .. } => "imap.expunge",
        OpSpec::ImapAppend { .. } => "imap.append",
        OpSpec::ImapMixed { .. } => "mixed.session",
    }
}

pub fn select_users(
    dataset: &Dataset,
    spec: &UserSpec,
    (shard, shards): (u32, u32),
) -> Result<Vec<AccountId>> {
    let mut users: Vec<AccountId> = match spec.set {
        UserSet::Regular => (0..dataset.users())
            .map(AccountId::Regular)
            .filter(|a| spec.min_inbox == 0 || dataset.inbox_size(*a) >= spec.min_inbox)
            .filter(|a| !spec.buckets || dataset.has_buckets(*a))
            .collect(),
        UserSet::Large => {
            let name = spec
                .account
                .as_deref()
                .ok_or_else(|| Error::config("users.set large needs users.account"))?;
            vec![
                dataset
                    .find_large(name)
                    .ok_or_else(|| Error::config(format!("no large account {name} in dataset")))?,
            ]
        }
    };
    if let Some(limit) = spec.limit {
        users.truncate(limit as usize);
    }
    if shards > 1 && spec.set == UserSet::Regular {
        users.retain(|a| dataset.ordinal(*a) % u64::from(shards) == u64::from(shard));
    }
    if users.is_empty() {
        return Err(Error::config("user selection is empty"));
    }
    Ok(users)
}

pub struct Session {
    pub client: ImapClient,
    pub selected: Option<String>,
    pub exists: u32,
    pub ops_left: u32,
}

pub struct WorkerState {
    pub index: usize,
    pub users: Arc<[AccountId]>,
    pub rng: Rng,
    pub session: Option<Session>,
    pub probes: Vec<IdleProbe>,
    pub probe_users: Vec<AccountId>,
    pub buf: Vec<u8>,
    pub toggle: bool,
}

impl WorkerState {
    pub fn new(ctx: &Ctx, index: usize, workers: usize) -> Self {
        WorkerState {
            index,
            users: ctx.worker_users(index, workers),
            rng: Rng::from_parts(&[ctx.workload_seed, index as u64]),
            session: None,
            probes: Vec::new(),
            probe_users: Vec::new(),
            buf: Vec::with_capacity(64 * 1024),
            toggle: false,
        }
    }

    pub fn pick_user(&mut self) -> AccountId {
        let i = self.rng.below_usize(self.users.len());
        self.users[i]
    }

    pub async fn prepare(&mut self, ctx: &Ctx) -> Result<()> {
        if let OpSpec::Smtp {
            probe,
            recipients,
            poll_gap,
            ..
        } = &ctx.cell.op
            && probe.is_imap()
        {
            let needed = *recipients as usize;
            if self.users.len() < needed {
                return Err(Error::config(format!(
                    "worker {} has {} users, needs {needed} probe recipients",
                    self.index,
                    self.users.len()
                )));
            }
            let mode = match probe {
                SmtpProbe::ImapPoll => ProbeMode::Poll(poll_gap.0),
                SmtpProbe::ImapStatus => ProbeMode::Status(poll_gap.0),
                _ => ProbeMode::Idle,
            };
            for account in self.users.iter().take(needed) {
                let probe = IdleProbe::start(
                    ctx.target.clone(),
                    ctx.dataset.address(*account),
                    ctx.dataset.password(*account),
                    mode,
                    PROBE_READY_TIMEOUT,
                )
                .await?;
                self.probes.push(probe);
                self.probe_users.push(*account);
            }
        }
        Ok(())
    }

    pub async fn restart_stream(&mut self, ctx: &Ctx) {
        if let Some(session) = self.session.take() {
            imap::end_session(ctx, session).await;
        }
        self.rng = Rng::from_parts(&[ctx.workload_seed, self.index as u64, STREAM_MEASURE]);
    }

    pub async fn close(&mut self, ctx: &Ctx) {
        if let Some(session) = self.session.take() {
            imap::end_session(ctx, session).await;
        }
        self.probes.clear();
    }
}

pub async fn execute(ctx: &Ctx, ws: &mut WorkerState, em: Emitter<'_>, timer: Timer) -> Result<()> {
    match &ctx.cell.op {
        OpSpec::Smtp { .. } => smtp::execute(ctx, ws, em, timer).await,
        OpSpec::ImapMixed { profile } => mixed::execute(ctx, ws, em, timer, profile).await,
        OpSpec::ImapLogin => imap::login(ctx, ws, em, timer).await,
        _ => imap::execute(ctx, ws, em).await,
    }
}

pub fn supports_open_loop(op: &OpSpec) -> bool {
    matches!(
        op,
        OpSpec::Smtp { .. } | OpSpec::ImapMixed { .. } | OpSpec::ImapLogin
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alias_duplicates_only_the_primary_sample() {
        let shared = Shared::new(
            Recorder::new(1, 10_000).expect("recorder"),
            "imap.fetch",
            100,
        );
        let em = Emitter::new(&shared, Some(0)).with_alias("imap.cold_op");
        em.sample_us("imap.select_cold", 900, PhaseTimes::default(), None);
        em.sample_us("imap.fetch", 500, PhaseTimes::default(), None);
        Emitter::new(&shared, Some(0)).sample_us("imap.fetch", 400, PhaseTimes::default(), None);
        let recorder = shared.recorder.lock().unwrap_or_else(|e| e.into_inner());
        assert_eq!(recorder.count(0, "imap.fetch"), 2);
        assert_eq!(recorder.count(0, "imap.cold_op"), 1);
        assert_eq!(recorder.count(0, "imap.select_cold"), 1);
    }
}
