mod recorder;
pub mod report;

use std::time::Instant;

pub use recorder::{Event, Recorder, Sample, StepStats, new_histogram as recorder_histogram};
pub use report::{RunReport, Slo, StepReport, Validity, merge_reports};

pub const SCHEMA: &str = "mailbench/1";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Connect,
    Tls,
    Greeting,
    Auth,
    Command,
}

pub const PHASES: usize = 5;

impl Phase {
    pub const ALL: [Phase; PHASES] = [
        Phase::Connect,
        Phase::Tls,
        Phase::Greeting,
        Phase::Auth,
        Phase::Command,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Phase::Connect => "connect",
            Phase::Tls => "tls",
            Phase::Greeting => "greeting",
            Phase::Auth => "auth",
            Phase::Command => "command",
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct PhaseTimes {
    us: [u64; PHASES],
    present: u8,
}

impl PhaseTimes {
    pub fn add(&mut self, phase: Phase, us: u64) {
        let i = phase as usize;
        self.us[i] += us;
        self.present |= 1 << i;
    }

    pub fn iter(&self) -> impl Iterator<Item = (Phase, u64)> + '_ {
        Phase::ALL
            .into_iter()
            .zip(self.us)
            .filter(|(phase, _)| self.present & (1 << *phase as usize) != 0)
    }
}

pub struct Timer {
    pub origin: Instant,
    last: Instant,
    pub phases: PhaseTimes,
}

impl Timer {
    pub fn start() -> Self {
        let now = Instant::now();
        Timer {
            origin: now,
            last: now,
            phases: PhaseTimes::default(),
        }
    }

    pub fn scheduled(origin: Instant) -> Self {
        Timer {
            origin,
            last: Instant::now(),
            phases: PhaseTimes::default(),
        }
    }

    pub fn mark(&mut self, phase: Phase) {
        let now = Instant::now();
        self.phases
            .add(phase, micros(now.saturating_duration_since(self.last)));
        self.last = now;
    }

    pub fn total_us(&self) -> u64 {
        micros(self.origin.elapsed())
    }

    pub fn since_origin_us(&self, at: Instant) -> u64 {
        micros(at.saturating_duration_since(self.origin))
    }
}

pub fn micros(d: std::time::Duration) -> u64 {
    u64::try_from(d.as_micros()).unwrap_or(u64::MAX)
}
