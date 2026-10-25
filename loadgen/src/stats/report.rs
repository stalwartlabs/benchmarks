use std::collections::BTreeMap;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use hdrhistogram::Histogram;
use hdrhistogram::serialization::{Deserializer, Serializer, V2DeflateSerializer};
use serde::{Deserialize, Serialize};

use super::recorder::{LabelStats, StepStats};
use super::{Phase, SCHEMA};
use crate::error::{Error, Result};

pub struct Validity;

impl Validity {
    pub const CPU_LIMIT_PCT: f64 = 70.0;
    pub const LATE_THRESHOLD_US: u64 = 10_000;
    pub const LATE_FRACTION: f64 = 0.01;
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct LatencyStats {
    pub mean: f64,
    pub min: u64,
    pub p50: u64,
    pub p90: u64,
    pub p95: u64,
    pub p99: u64,
    pub p999: u64,
    pub max: u64,
}

impl LatencyStats {
    pub fn from_histogram(hist: &Histogram<u64>) -> Self {
        if hist.is_empty() {
            return LatencyStats::default();
        }
        LatencyStats {
            mean: (hist.mean() * 10.0).round() / 10.0,
            min: hist.min(),
            p50: hist.value_at_quantile(0.50),
            p90: hist.value_at_quantile(0.90),
            p95: hist.value_at_quantile(0.95),
            p99: hist.value_at_quantile(0.99),
            p999: hist.value_at_quantile(0.999),
            max: hist.max(),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PhaseReport {
    pub count: u64,
    #[serde(flatten)]
    pub latency: LatencyStats,
    pub histogram: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ItemStats {
    pub count: u64,
    pub sum: u64,
    pub min: u64,
    pub max: u64,
    pub mean: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OpReport {
    pub count: u64,
    pub errors: u64,
    pub error_rate: f64,
    pub throughput: f64,
    #[serde(flatten)]
    pub latency: LatencyStats,
    pub histogram: String,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub phases: BTreeMap<String, PhaseReport>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub items: Option<ItemStats>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub error_kinds: BTreeMap<String, u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub error_samples: Vec<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct GeneratorStats {
    pub cpu_mean_pct: Option<f64>,
    pub cpu_max_pct: Option<f64>,
    pub arrivals: u64,
    pub late: u64,
    pub late_pct: f64,
    pub max_late_us: u64,
    pub dropped: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Slo {
    pub p99_us: u64,
    pub max_error_rate: f64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub labels: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StepReport {
    pub index: usize,
    pub target_rate: Option<f64>,
    pub duration_s: f64,
    pub valid: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub invalid_reasons: Vec<String>,
    pub slo_met: Option<bool>,
    pub generator: GeneratorStats,
    pub ops: BTreeMap<String, OpReport>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunReport {
    pub schema: String,
    pub scenario: String,
    pub cell: String,
    pub family: String,
    pub mode: String,
    pub target: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub variant: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    pub hosts: Vec<String>,
    pub shards: Vec<String>,
    pub dataset: String,
    pub seed: u64,
    pub started_at_ms: u64,
    pub finished_at_ms: u64,
    pub rtt_us: Option<LatencyStats>,
    pub load: serde_json::Value,
    pub slo: Option<Slo>,
    pub steps: Vec<StepReport>,
    pub valid: bool,
    pub best_step: Option<usize>,
    pub best_rate: Option<f64>,
}

pub fn encode_histogram(hist: &Histogram<u64>) -> Result<String> {
    let mut buf = Vec::new();
    V2DeflateSerializer::new()
        .serialize(hist, &mut buf)
        .map_err(|err| Error::config(format!("histogram serialization: {err:?}")))?;
    Ok(STANDARD.encode(buf))
}

pub fn decode_histogram(text: &str) -> Result<Histogram<u64>> {
    let bytes = STANDARD
        .decode(text)
        .map_err(|err| Error::config(format!("histogram base64: {err}")))?;
    Deserializer::new()
        .deserialize(&mut bytes.as_slice())
        .map_err(|err| Error::config(format!("histogram decode: {err:?}")))
}

impl OpReport {
    fn from_label(label: &LabelStats, duration_s: f64) -> Result<Self> {
        let count = label.total.len();
        let attempts = count + label.errors;
        let mut phases = BTreeMap::new();
        for (phase, hist) in Phase::ALL.iter().zip(&label.phases) {
            if let Some(hist) = hist {
                phases.insert(
                    phase.name().to_string(),
                    PhaseReport {
                        count: hist.len(),
                        latency: LatencyStats::from_histogram(hist),
                        histogram: encode_histogram(hist)?,
                    },
                );
            }
        }
        Ok(OpReport {
            count,
            errors: label.errors,
            error_rate: ratio(label.errors, attempts),
            throughput: rate(count, duration_s),
            latency: LatencyStats::from_histogram(&label.total),
            histogram: encode_histogram(&label.total)?,
            phases,
            items: (label.items_count > 0).then(|| ItemStats {
                count: label.items_count,
                sum: label.items_sum,
                min: label.items_min,
                max: label.items_max,
                mean: label.items_sum as f64 / label.items_count as f64,
            }),
            error_kinds: label
                .error_kinds
                .iter()
                .map(|(k, v)| ((*k).to_string(), *v))
                .collect(),
            error_samples: label.error_samples.clone(),
        })
    }
}

fn ratio(part: u64, whole: u64) -> f64 {
    if whole == 0 {
        0.0
    } else {
        part as f64 / whole as f64
    }
}

fn rate(count: u64, duration_s: f64) -> f64 {
    if duration_s > 0.0 {
        (count as f64 / duration_s * 100.0).round() / 100.0
    } else {
        0.0
    }
}

pub struct CpuWindow {
    pub mean: Option<f64>,
    pub max: Option<f64>,
}

impl StepReport {
    pub fn build(
        index: usize,
        stats: &StepStats,
        duration_s: f64,
        target_rate: Option<f64>,
        cpu: CpuWindow,
    ) -> Result<Self> {
        let mut ops = BTreeMap::new();
        for label in &stats.labels {
            ops.insert(
                label.label.to_string(),
                OpReport::from_label(label, duration_s)?,
            );
        }
        Ok(StepReport {
            index,
            target_rate,
            duration_s,
            valid: true,
            invalid_reasons: Vec::new(),
            slo_met: None,
            generator: GeneratorStats {
                cpu_mean_pct: cpu.mean,
                cpu_max_pct: cpu.max,
                arrivals: stats.arrivals,
                late: stats.late,
                late_pct: ratio(stats.late, stats.arrivals) * 100.0,
                max_late_us: stats.max_late_us,
                dropped: stats.dropped,
            },
            ops,
        })
    }

    pub fn evaluate(&mut self, slo: Option<&Slo>) {
        self.invalid_reasons.clear();
        let generator = &self.generator;
        if let Some(cpu) = generator.cpu_mean_pct
            && cpu > Validity::CPU_LIMIT_PCT
        {
            self.invalid_reasons.push(format!(
                "generator CPU {cpu:.1}% > {}%",
                Validity::CPU_LIMIT_PCT
            ));
        }
        if generator.arrivals > 0
            && ratio(generator.late, generator.arrivals) > Validity::LATE_FRACTION
        {
            self.invalid_reasons.push(format!(
                "{:.2}% of arrivals late by more than {} ms",
                generator.late_pct,
                Validity::LATE_THRESHOLD_US / 1000
            ));
        }
        if generator.dropped > 0 {
            self.invalid_reasons
                .push(format!("{} arrivals dropped", generator.dropped));
        }
        self.valid = self.invalid_reasons.is_empty();
        self.slo_met = slo.map(|slo| {
            let mut checked = 0;
            let all_ok = self
                .ops
                .iter()
                .filter(|(label, _)| {
                    slo.labels.is_empty() || slo.labels.iter().any(|l| l == *label)
                })
                .all(|(_, op)| {
                    checked += 1;
                    op.count > 0
                        && op.latency.p99 <= slo.p99_us
                        && op.error_rate <= slo.max_error_rate
                });
            all_ok && checked > 0
        });
    }
}

impl RunReport {
    pub fn finalize(&mut self) {
        for step in &mut self.steps {
            step.evaluate(self.slo.as_ref());
        }
        self.schema = SCHEMA.to_string();
        self.select_best();
    }

    pub fn select_best(&mut self) {
        self.valid = self.steps.iter().all(|s| s.valid);
        let best = self
            .steps
            .iter()
            .filter(|s| s.valid && s.slo_met == Some(true))
            .max_by(|a, b| {
                a.target_rate
                    .unwrap_or(0.0)
                    .total_cmp(&b.target_rate.unwrap_or(0.0))
            });
        self.best_step = best.map(|s| s.index);
        self.best_rate = best.and_then(|s| s.target_rate);
    }
}

fn merge_histogram(into: &mut String, from: &str) -> Result<Histogram<u64>> {
    let mut a = decode_histogram(into)?;
    let b = decode_histogram(from)?;
    a.add(&b)
        .map_err(|err| Error::config(format!("histogram merge: {err:?}")))?;
    *into = encode_histogram(&a)?;
    Ok(a)
}

fn merge_op(into: &mut OpReport, from: &OpReport) -> Result<()> {
    let hist = merge_histogram(&mut into.histogram, &from.histogram)?;
    into.latency = LatencyStats::from_histogram(&hist);
    into.count += from.count;
    into.errors += from.errors;
    into.error_rate = ratio(into.errors, into.count + into.errors);
    into.throughput = ((into.throughput + from.throughput) * 100.0).round() / 100.0;
    for (name, phase) in &from.phases {
        match into.phases.get_mut(name) {
            Some(existing) => {
                let hist = merge_histogram(&mut existing.histogram, &phase.histogram)?;
                existing.count += phase.count;
                existing.latency = LatencyStats::from_histogram(&hist);
            }
            None => {
                into.phases.insert(name.clone(), phase.clone());
            }
        }
    }
    into.items = match (into.items.take(), &from.items) {
        (Some(a), Some(b)) => {
            let count = a.count + b.count;
            let sum = a.sum + b.sum;
            Some(ItemStats {
                count,
                sum,
                min: a.min.min(b.min),
                max: a.max.max(b.max),
                mean: sum as f64 / count.max(1) as f64,
            })
        }
        (a, b) => a.or_else(|| b.clone()),
    };
    for (kind, count) in &from.error_kinds {
        *into.error_kinds.entry(kind.clone()).or_default() += count;
    }
    for sample in &from.error_samples {
        if into.error_samples.len() < 10 {
            into.error_samples.push(sample.clone());
        }
    }
    Ok(())
}

fn merge_step(into: &mut StepReport, from: &StepReport) -> Result<()> {
    into.duration_s = into.duration_s.max(from.duration_s);
    into.target_rate = match (into.target_rate, from.target_rate) {
        (Some(a), Some(b)) => Some(a.max(b)),
        (a, b) => a.or(b),
    };
    let g = &mut into.generator;
    let f = &from.generator;
    g.cpu_mean_pct = max_opt(g.cpu_mean_pct, f.cpu_mean_pct);
    g.cpu_max_pct = max_opt(g.cpu_max_pct, f.cpu_max_pct);
    g.arrivals += f.arrivals;
    g.late += f.late;
    g.dropped += f.dropped;
    g.max_late_us = g.max_late_us.max(f.max_late_us);
    g.late_pct = ratio(g.late, g.arrivals) * 100.0;
    for (label, op) in &from.ops {
        match into.ops.get_mut(label) {
            Some(existing) => merge_op(existing, op)?,
            None => {
                into.ops.insert(label.clone(), op.clone());
            }
        }
    }
    Ok(())
}

fn max_opt(a: Option<f64>, b: Option<f64>) -> Option<f64> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a.max(b)),
        (a, b) => a.or(b),
    }
}

pub fn merge_reports(reports: Vec<RunReport>) -> Result<RunReport> {
    let mut iter = reports.into_iter();
    let mut merged = iter
        .next()
        .ok_or_else(|| Error::config("no reports to merge"))?;
    for report in iter {
        if report.cell != merged.cell || report.target != merged.target {
            return Err(Error::config(format!(
                "cannot merge {}/{} into {}/{}",
                report.cell, report.target, merged.cell, merged.target
            )));
        }
        merged.hosts.extend(report.hosts);
        merged.shards.extend(report.shards);
        merged.started_at_ms = merged.started_at_ms.min(report.started_at_ms);
        merged.finished_at_ms = merged.finished_at_ms.max(report.finished_at_ms);
        for step in &report.steps {
            match merged.steps.iter_mut().find(|s| s.index == step.index) {
                Some(existing) => merge_step(existing, step)?,
                None => merged.steps.push(step.clone()),
            }
        }
        for step in &report.steps {
            if let Some(existing) = merged.steps.iter_mut().find(|s| s.index == step.index) {
                existing
                    .invalid_reasons
                    .extend(step.invalid_reasons.iter().cloned());
            }
        }
    }
    merged.steps.sort_unstable_by_key(|s| s.index);
    let carried: Vec<Vec<String>> = merged
        .steps
        .iter_mut()
        .map(|s| std::mem::take(&mut s.invalid_reasons))
        .collect();
    merged.finalize();
    for (step, reasons) in merged.steps.iter_mut().zip(carried) {
        for reason in reasons {
            if !step.invalid_reasons.contains(&reason) {
                step.invalid_reasons.push(reason);
            }
        }
        step.valid = step.invalid_reasons.is_empty();
    }
    merged.select_best();
    Ok(merged)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stats::{Event, PhaseTimes, Recorder, Sample};

    fn report(values: &[u64], cpu: f64, dropped: u64) -> RunReport {
        let mut recorder = Recorder::new(1, Validity::LATE_THRESHOLD_US).expect("recorder");
        for value in values {
            let mut phases = PhaseTimes::default();
            phases.add(Phase::Command, *value / 2);
            recorder.record(Event::Sample(Sample {
                label: "op",
                step: 0,
                total_us: *value,
                phases,
                items: Some(1),
            }));
        }
        for _ in 0..dropped {
            recorder.record(Event::Dropped { step: 0 });
        }
        let step = StepReport::build(
            0,
            &recorder.steps[0],
            10.0,
            Some(100.0),
            CpuWindow {
                mean: Some(cpu),
                max: Some(cpu),
            },
        )
        .expect("step");
        let mut report = RunReport {
            schema: String::new(),
            scenario: "s".into(),
            cell: "c".into(),
            family: "f".into(),
            mode: "throughput".into(),
            target: "t".into(),
            variant: None,
            profile: None,
            hosts: vec!["h".into()],
            shards: vec!["0/2".into()],
            dataset: "c".into(),
            seed: 1,
            started_at_ms: 0,
            finished_at_ms: 0,
            rtt_us: None,
            load: serde_json::Value::Null,
            slo: Some(Slo {
                p99_us: 5_000,
                max_error_rate: 0.001,
                labels: vec![],
            }),
            steps: vec![step],
            valid: true,
            best_step: None,
            best_rate: None,
        };
        report.finalize();
        report
    }

    #[test]
    fn merge_adds_histograms_and_rates() {
        let a = report(&[1000; 100], 20.0, 0);
        let b = report(&[3000; 300], 30.0, 0);
        assert_eq!(a.best_step, Some(0));
        let merged = merge_reports(vec![a, b]).expect("merge");
        let op = &merged.steps[0].ops["op"];
        assert_eq!(op.count, 400);
        assert_eq!(op.throughput, 40.0);
        assert!(op.latency.p50 >= 2990 && op.latency.p50 <= 3010);
        assert_eq!(op.phases["command"].count, 400);
        assert_eq!(merged.steps[0].target_rate, Some(100.0));
        assert_eq!(merged.steps[0].generator.cpu_mean_pct, Some(30.0));
        assert!(merged.valid);
        assert_eq!(merged.best_rate, Some(100.0));
    }

    #[test]
    fn invalid_host_invalidates_merge() {
        let a = report(&[1000; 10], 85.0, 0);
        assert!(!a.valid);
        let b = report(&[1000; 10], 10.0, 2);
        assert!(!b.valid);
        let merged = merge_reports(vec![a, b]).expect("merge");
        assert!(!merged.valid);
        assert_eq!(merged.steps[0].invalid_reasons.len(), 2);
        assert_eq!(merged.best_step, None);
    }

    #[test]
    fn slo_breach_is_reported() {
        let a = report(&[10_000; 50], 10.0, 0);
        assert_eq!(a.steps[0].slo_met, Some(false));
        assert_eq!(a.best_step, None);
    }
}
