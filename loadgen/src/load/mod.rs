mod monitor;

use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::sync::{Barrier, Semaphore, watch};

pub use monitor::{CpuMonitor, cpu_window};

use crate::error::{Error, Result};
use crate::ops::{Ctx, Emitter, Shared, WorkerState, execute};
use crate::rng::Rng;
use crate::scenario::{ClosedSpec, OpenSpec, SloSpec};
use crate::stats::{Event, StepStats, Timer, micros};

const ERROR_BACKOFF: Duration = Duration::from_millis(50);
const STOP_POLL: Duration = Duration::from_millis(100);
const DRAIN_GRACE: Duration = Duration::from_secs(5);

pub struct Window {
    pub start: Instant,
    pub end: Instant,
    pub rate: Option<f64>,
}

impl Window {
    pub fn seconds(&self) -> f64 {
        self.end.saturating_duration_since(self.start).as_secs_f64()
    }
}

pub async fn run_closed(
    ctx: Arc<Ctx>,
    spec: &ClosedSpec,
    shared: Arc<Shared>,
) -> Result<Vec<Window>> {
    let sessions = spec.sessions.max(1) as usize;
    let barrier = Arc::new(Barrier::new(sessions + 1));
    let (start_tx, start_rx) = watch::channel::<Option<Instant>>(None);
    let mut handles = Vec::with_capacity(sessions);
    for index in 0..sessions {
        let ctx = ctx.clone();
        let shared = shared.clone();
        let barrier = barrier.clone();
        let mut start_rx = start_rx.clone();
        let think = spec.think.0;
        let max_duration = spec.max_duration.0;
        handles.push(tokio::spawn(async move {
            let mut ws = WorkerState::new(&ctx, index, sessions);
            let prepared = ws.prepare(&ctx).await;
            barrier.wait().await;
            prepared?;
            let measure_start = start_rx
                .wait_for(Option::is_some)
                .await
                .map_err(|_| Error::Protocol("run aborted".into()))?
                .ok_or_else(|| Error::Protocol("run aborted".into()))?;
            let deadline = measure_start + max_duration;
            let primary = ctx.primary_label();
            let mut measuring = false;
            while !shared.stopped() && Instant::now() < deadline {
                let step = (Instant::now() >= measure_start).then_some(0);
                if step.is_some() && !measuring {
                    measuring = true;
                    ws.restart_stream(&ctx).await;
                }
                let em = Emitter::new(&shared, step);
                match tokio::time::timeout(ctx.timeout, execute(&ctx, &mut ws, em, Timer::start()))
                    .await
                {
                    Ok(Ok(())) => {}
                    Ok(Err(err)) => {
                        em.error(primary, &err);
                        ws.session = None;
                        tokio::time::sleep(ERROR_BACKOFF).await;
                    }
                    Err(_) => {
                        em.error(primary, &Error::Timeout(ctx.timeout));
                        ws.session = None;
                    }
                }
                if !think.is_zero() {
                    tokio::time::sleep(think).await;
                }
            }
            ws.close(&ctx).await;
            Ok::<(), Error>(())
        }));
    }
    barrier.wait().await;
    let measure_start = Instant::now() + spec.warmup.0;
    let deadline = measure_start + spec.max_duration.0;
    let _ = start_tx.send(Some(measure_start));
    let end = loop {
        let now = Instant::now();
        if shared.stopped() {
            break now;
        }
        if now >= deadline {
            shared
                .stop
                .store(true, std::sync::atomic::Ordering::Relaxed);
            break now;
        }
        if handles.iter().all(|h| h.is_finished()) {
            break now;
        }
        tokio::time::sleep(STOP_POLL).await;
    };
    let mut first_error = None;
    for handle in handles {
        match handle.await {
            Ok(Ok(())) => {}
            Ok(Err(err)) => {
                first_error.get_or_insert(err);
            }
            Err(err) => {
                first_error.get_or_insert(Error::Protocol(format!("worker panicked: {err}")));
            }
        }
    }
    if let Some(err) = first_error {
        if end < measure_start {
            return Err(err);
        }
        eprintln!("worker error: {err}");
    }
    Ok(vec![Window {
        start: measure_start,
        end: end.max(measure_start),
        rate: None,
    }])
}

enum Phase {
    Warmup,
    Measure(u16),
}

pub async fn run_open(
    ctx: Arc<Ctx>,
    spec: &OpenSpec,
    shared: Arc<Shared>,
    shards: u32,
    slo: Option<&SloSpec>,
) -> Result<Vec<Window>> {
    let rates: Vec<f64> = spec.rate_list();
    if rates.is_empty() || rates.iter().any(|r| *r <= 0.0) {
        return Err(Error::config("open loop needs positive rates"));
    }
    let divisor = f64::from(shards.max(1));
    let max_inflight = spec.max_inflight.max(1);
    let semaphore = Arc::new(Semaphore::new(max_inflight as usize));
    let mut rng = Rng::from_parts(&[ctx.workload_seed, 0x6f70_656e]);
    let mut plan: Vec<(Duration, f64, Phase)> = Vec::with_capacity(rates.len() * 2 + 1);
    plan.push((spec.warmup.0, rates[0] / divisor, Phase::Warmup));
    for (i, rate) in rates.iter().enumerate() {
        if !spec.step_warmup.0.is_zero() {
            plan.push((spec.step_warmup.0, rate / divisor, Phase::Warmup));
        }
        plan.push((
            spec.step_duration.0,
            rate / divisor,
            Phase::Measure(i as u16),
        ));
    }
    let mut windows = Vec::with_capacity(rates.len());
    let mut failures = 0;
    let mut next = Instant::now();
    for (duration, rate, phase) in plan {
        let phase_start = Instant::now().max(next);
        let phase_end = phase_start + duration;
        let step = match phase {
            Phase::Warmup => None,
            Phase::Measure(i) => Some(i),
        };
        next = phase_start;
        loop {
            next += Duration::from_secs_f64(rng.exp(1.0 / rate));
            if next >= phase_end {
                break;
            }
            tokio::time::sleep_until(next.into()).await;
            let late = micros(Instant::now().saturating_duration_since(next));
            if let Some(step) = step {
                shared.record(Event::Arrival {
                    step,
                    late_us: late,
                });
            }
            let Ok(permit) = semaphore.clone().try_acquire_owned() else {
                if let Some(step) = step {
                    shared.record(Event::Dropped { step });
                }
                continue;
            };
            let ctx = ctx.clone();
            let shared = shared.clone();
            let scheduled = next;
            let seed = rng.next_u64();
            tokio::spawn(async move {
                let mut ws = WorkerState::new(&ctx, 0, 1);
                ws.rng = Rng::new(seed);
                let em = Emitter::new(&shared, step);
                let primary = ctx.primary_label();
                match tokio::time::timeout(
                    ctx.timeout,
                    execute(&ctx, &mut ws, em, Timer::scheduled(scheduled)),
                )
                .await
                {
                    Ok(Ok(())) => {}
                    Ok(Err(err)) => em.error(primary, &err),
                    Err(_) => em.error(primary, &Error::Timeout(ctx.timeout)),
                }
                drop(permit);
            });
        }
        next = phase_end;
        if let Phase::Measure(i) = phase {
            windows.push(Window {
                start: phase_start,
                end: phase_end,
                rate: Some(rate * divisor),
            });
            if let (Some(slo), Some(prev)) = (slo, i.checked_sub(1)) {
                let met = {
                    let recorder = shared.recorder.lock().unwrap_or_else(|e| e.into_inner());
                    recorder
                        .steps
                        .get(usize::from(prev))
                        .is_some_and(|s| step_meets_slo(s, slo))
                };
                failures = if met { 0 } else { failures + 1 };
                if failures >= spec.stop_after_failures.max(1) {
                    eprintln!(
                        "stopping ladder after step {i}: SLO missed {failures} times in a row"
                    );
                    break;
                }
            }
        }
    }
    let _ = tokio::time::timeout(
        ctx.timeout + DRAIN_GRACE,
        semaphore.acquire_many(max_inflight),
    )
    .await;
    Ok(windows)
}

fn step_meets_slo(step: &StepStats, slo: &SloSpec) -> bool {
    let p99_us = micros(slo.p99.0);
    let mut checked = 0;
    let ok = step
        .labels
        .iter()
        .filter(|l| slo.labels.is_empty() || slo.labels.iter().any(|s| s == l.label))
        .all(|l| {
            checked += 1;
            let count = l.total.len();
            let attempts = count + l.errors;
            count > 0
                && l.total.value_at_quantile(0.99) <= p99_us
                && (l.errors as f64) <= slo.max_error_rate * attempts as f64
        });
    ok && checked > 0
}
