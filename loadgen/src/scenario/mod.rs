mod duration;
mod file;
mod op;
mod profile;

pub use duration::Dur;
pub use file::{ScenarioFile, list_dir};
pub use op::{
    CopyMode, FetchKind, ImapRange, MixedProfile, OpSpec, SizeSpec, SmtpPort, SmtpProbe, SortKey,
};
pub use profile::Profile;

use serde::{Deserialize, Serialize};

use crate::dataset::DatasetName;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Latency,
    Throughput,
}

impl Mode {
    pub fn name(self) -> &'static str {
        match self {
            Mode::Latency => "latency",
            Mode::Throughput => "throughput",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CacheState {
    Warm,
    Cold,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(untagged)]
pub enum LoadHosts {
    Count(u32),
    All(AllHosts),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AllHosts {
    All,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "model", rename_all = "snake_case", deny_unknown_fields)]
pub enum LoadSpec {
    Closed(ClosedSpec),
    Open(OpenSpec),
}

fn default_session_ops() -> u32 {
    100
}

fn default_warmup() -> Dur {
    Dur(std::time::Duration::from_secs(60))
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ClosedSpec {
    pub sessions: u32,
    #[serde(default = "default_warmup")]
    pub warmup: Dur,
    pub samples: u64,
    pub max_duration: Dur,
    #[serde(default)]
    pub think: Dur,
    #[serde(default = "default_session_ops")]
    pub session_ops: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Ladder {
    pub start: f64,
    pub factor: f64,
    pub steps: u32,
}

fn default_max_inflight() -> u32 {
    20_000
}

fn default_stop_after() -> u32 {
    2
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct OpenSpec {
    #[serde(default)]
    pub rates: Vec<f64>,
    #[serde(default)]
    pub ladder: Option<Ladder>,
    #[serde(default = "default_warmup")]
    pub warmup: Dur,
    pub step_duration: Dur,
    #[serde(default)]
    pub step_warmup: Dur,
    #[serde(default = "default_max_inflight")]
    pub max_inflight: u32,
    #[serde(default = "default_stop_after")]
    pub stop_after_failures: u32,
}

impl OpenSpec {
    pub fn rate_list(&self) -> Vec<f64> {
        match &self.ladder {
            Some(ladder) => (0..ladder.steps)
                .map(|i| (ladder.start * ladder.factor.powi(i as i32) * 100.0).round() / 100.0)
                .collect(),
            None => self.rates.clone(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Variant {
    pub target: String,
    pub name: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum UserSet {
    Regular,
    Large,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct UserSpec {
    pub set: UserSet,
    #[serde(default)]
    pub account: Option<String>,
    #[serde(default)]
    pub min_inbox: u32,
    #[serde(default)]
    pub buckets: bool,
    #[serde(default)]
    pub limit: Option<u32>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SloSpec {
    pub p99: Dur,
    #[serde(default = "default_error_rate")]
    pub max_error_rate: f64,
    #[serde(default)]
    pub labels: Vec<String>,
}

fn default_error_rate() -> f64 {
    0.001
}

fn default_timeout() -> Dur {
    Dur(std::time::Duration::from_secs(120))
}

fn default_repetitions() -> u32 {
    3
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Cell {
    pub id: String,
    pub scenario: String,
    pub title: String,
    pub family: String,
    pub mode: Mode,
    pub targets: Vec<String>,
    #[serde(default)]
    pub variants: Vec<Variant>,
    #[serde(default = "default_repetitions")]
    pub repetitions: u32,
    pub cache: CacheState,
    pub load_hosts: LoadHosts,
    pub dataset: DatasetName,
    #[serde(default = "default_timeout")]
    pub timeout: Dur,
    #[serde(default)]
    pub slo: Option<SloSpec>,
    pub load: LoadSpec,
    pub users: UserSpec,
    pub op: OpSpec,
    #[serde(default)]
    pub cold_open: bool,
    #[serde(default)]
    pub group: Option<String>,
}
