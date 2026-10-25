use std::time::{Duration, Instant};

use tokio::sync::watch;
use tokio::task::JoinHandle;

use crate::stats::report::CpuWindow;

const SAMPLE_INTERVAL: Duration = Duration::from_secs(1);

pub struct CpuMonitor {
    handle: JoinHandle<Vec<(Instant, f64)>>,
    stop: watch::Sender<bool>,
}

struct CpuTimes {
    busy: u64,
    total: u64,
}

fn read_cpu() -> Option<CpuTimes> {
    let text = std::fs::read_to_string("/proc/stat").ok()?;
    let line = text.lines().next()?.strip_prefix("cpu ")?;
    let values: Vec<u64> = line
        .split_whitespace()
        .filter_map(|v| v.parse().ok())
        .collect();
    let [user, nice, system, idle, iowait, irq, softirq, steal, ..] = values.as_slice() else {
        return None;
    };
    let idle_all = idle + iowait;
    let busy = user + nice + system + irq + softirq + steal;
    Some(CpuTimes {
        busy,
        total: busy + idle_all,
    })
}

impl CpuMonitor {
    pub fn start() -> Self {
        let (stop, mut rx) = watch::channel(false);
        let handle = tokio::spawn(async move {
            let mut samples = Vec::with_capacity(4096);
            let mut previous = read_cpu();
            let mut ticker = tokio::time::interval(SAMPLE_INTERVAL);
            ticker.tick().await;
            loop {
                tokio::select! {
                    _ = ticker.tick() => {}
                    _ = rx.changed() => break,
                }
                let current = read_cpu();
                if let (Some(prev), Some(cur)) = (&previous, &current) {
                    let total = cur.total.saturating_sub(prev.total);
                    if total > 0 {
                        let busy = cur.busy.saturating_sub(prev.busy);
                        samples.push((Instant::now(), busy as f64 * 100.0 / total as f64));
                    }
                }
                previous = current;
            }
            samples
        });
        CpuMonitor { handle, stop }
    }

    pub async fn finish(self) -> Vec<(Instant, f64)> {
        let _ = self.stop.send(true);
        self.handle.await.unwrap_or_default()
    }
}

pub fn cpu_window(samples: &[(Instant, f64)], start: Instant, end: Instant) -> CpuWindow {
    let mut sum = 0.0;
    let mut count = 0usize;
    let mut max = f64::MIN;
    for (_, value) in samples.iter().filter(|(at, _)| *at > start && *at <= end) {
        sum += value;
        count += 1;
        max = max.max(*value);
    }
    if count == 0 {
        CpuWindow {
            mean: None,
            max: None,
        }
    } else {
        CpuWindow {
            mean: Some((sum / count as f64 * 10.0).round() / 10.0),
            max: Some((max * 10.0).round() / 10.0),
        }
    }
}
