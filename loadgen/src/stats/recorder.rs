use hdrhistogram::Histogram;

use super::{PHASES, PhaseTimes};
use crate::error::{Error, Result};

pub const HIST_LOW_US: u64 = 1;
pub const HIST_HIGH_US: u64 = 3_600_000_000;
pub const HIST_SIGFIG: u8 = 3;
const MAX_ERROR_SAMPLES: usize = 5;

pub fn new_histogram() -> Result<Histogram<u64>> {
    let mut hist = Histogram::new_with_bounds(HIST_LOW_US, HIST_HIGH_US, HIST_SIGFIG)
        .map_err(|err| Error::config(format!("histogram: {err}")))?;
    hist.auto(true);
    Ok(hist)
}

pub struct Sample {
    pub label: &'static str,
    pub step: u16,
    pub total_us: u64,
    pub phases: PhaseTimes,
    pub items: Option<u64>,
}

pub enum Event {
    Sample(Sample),
    Error {
        label: &'static str,
        step: u16,
        kind: &'static str,
        message: String,
    },
    Arrival {
        step: u16,
        late_us: u64,
    },
    Dropped {
        step: u16,
    },
}

pub struct LabelStats {
    pub label: &'static str,
    pub total: Histogram<u64>,
    pub phases: [Option<Histogram<u64>>; PHASES],
    pub errors: u64,
    pub error_kinds: Vec<(&'static str, u64)>,
    pub error_samples: Vec<String>,
    pub items_sum: u64,
    pub items_count: u64,
    pub items_min: u64,
    pub items_max: u64,
}

impl LabelStats {
    fn new(label: &'static str, template: &Histogram<u64>) -> Self {
        LabelStats {
            label,
            total: template.clone(),
            phases: Default::default(),
            errors: 0,
            error_kinds: Vec::new(),
            error_samples: Vec::new(),
            items_sum: 0,
            items_count: 0,
            items_min: u64::MAX,
            items_max: 0,
        }
    }

    fn record(&mut self, sample: &Sample, template: &Histogram<u64>) {
        self.total
            .saturating_record(sample.total_us.max(HIST_LOW_US));
        for (phase, us) in sample.phases.iter() {
            self.phases[phase as usize]
                .get_or_insert_with(|| template.clone())
                .saturating_record(us.max(HIST_LOW_US));
        }
        if let Some(items) = sample.items {
            self.items_sum += items;
            self.items_count += 1;
            self.items_min = self.items_min.min(items);
            self.items_max = self.items_max.max(items);
        }
    }

    #[cold]
    fn record_error(&mut self, kind: &'static str, message: String) {
        self.errors += 1;
        match self.error_kinds.iter_mut().find(|(k, _)| *k == kind) {
            Some((_, count)) => *count += 1,
            None => self.error_kinds.push((kind, 1)),
        }
        if self.error_samples.len() < MAX_ERROR_SAMPLES {
            self.error_samples.push(message);
        }
    }
}

#[derive(Default)]
pub struct StepStats {
    pub labels: Vec<LabelStats>,
    pub arrivals: u64,
    pub late: u64,
    pub dropped: u64,
    pub max_late_us: u64,
}

impl StepStats {
    fn label(&mut self, label: &'static str, template: &Histogram<u64>) -> &mut LabelStats {
        match self.labels.iter().position(|l| l.label == label) {
            Some(pos) => &mut self.labels[pos],
            None => {
                self.labels.push(LabelStats::new(label, template));
                let last = self.labels.len() - 1;
                &mut self.labels[last]
            }
        }
    }
}

pub struct Recorder {
    pub steps: Vec<StepStats>,
    late_threshold_us: u64,
    template: Histogram<u64>,
}

impl Recorder {
    pub fn new(steps: usize, late_threshold_us: u64) -> Result<Self> {
        Ok(Recorder {
            steps: (0..steps).map(|_| StepStats::default()).collect(),
            late_threshold_us,
            template: new_histogram()?,
        })
    }

    pub fn record(&mut self, event: Event) {
        let threshold = self.late_threshold_us;
        let template = &self.template;
        let steps = &mut self.steps;
        match event {
            Event::Sample(sample) => {
                if let Some(step) = steps.get_mut(usize::from(sample.step)) {
                    step.label(sample.label, template).record(&sample, template);
                }
            }
            Event::Error {
                label,
                step,
                kind,
                message,
            } => {
                if let Some(step) = steps.get_mut(usize::from(step)) {
                    step.label(label, template).record_error(kind, message);
                }
            }
            Event::Arrival { step, late_us } => {
                if let Some(step) = steps.get_mut(usize::from(step)) {
                    step.arrivals += 1;
                    if late_us > threshold {
                        step.late += 1;
                    }
                    step.max_late_us = step.max_late_us.max(late_us);
                }
            }
            Event::Dropped { step } => {
                if let Some(step) = steps.get_mut(usize::from(step)) {
                    step.dropped += 1;
                }
            }
        }
    }

    pub fn count(&self, step: u16, label: &str) -> u64 {
        self.steps
            .get(usize::from(step))
            .and_then(|s| s.labels.iter().find(|l| l.label == label))
            .map_or(0, |l| l.total.len())
    }
}
