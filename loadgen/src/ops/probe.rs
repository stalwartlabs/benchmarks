use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::net::UdpSocket;
use tokio::sync::{Notify, oneshot, watch};
use tokio::task::JoinHandle;

use crate::error::{Error, Result};
use crate::proto::imap::ImapClient;
use crate::stats::{Timer, micros};
use crate::target::Target;

const REIDLE_AFTER: Duration = Duration::from_secs(20 * 60);
const RECONNECT_DELAY: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, Debug)]
pub enum ProbeMode {
    Idle,
    Poll(Duration),
    Status(Duration),
}

#[derive(Clone, Copy, Debug)]
pub struct Seen {
    pub exists: u32,
    pub at: Instant,
    pub rtt_us: u64,
}

type SeenTx = watch::Sender<Option<Seen>>;

pub struct IdleProbe {
    rx: watch::Receiver<Option<Seen>>,
    armed: Arc<Arm>,
    task: JoinHandle<()>,
}

#[derive(Default)]
struct Arm {
    notify: Notify,
    want: AtomicU32,
}

impl IdleProbe {
    pub async fn start(
        target: Arc<Target>,
        user: String,
        password: String,
        mode: ProbeMode,
        ready_timeout: Duration,
    ) -> Result<Self> {
        let (tx, mut rx) = watch::channel(None);
        let armed = Arc::new(Arm::default());
        let waiter = armed.clone();
        let task = tokio::spawn(async move {
            loop {
                let result = match mode {
                    ProbeMode::Idle => idle_loop(&target, &user, &password, &tx).await,
                    ProbeMode::Poll(gap) => {
                        poll_loop(&target, &user, &password, &tx, &waiter, gap, Check::Noop).await
                    }
                    ProbeMode::Status(gap) => {
                        poll_loop(&target, &user, &password, &tx, &waiter, gap, Check::Status).await
                    }
                };
                if let Err(err) = result {
                    eprintln!("idle probe {user}: {err}");
                }
                if tx.is_closed() {
                    return;
                }
                tokio::time::sleep(RECONNECT_DELAY).await;
            }
        });
        tokio::time::timeout(ready_timeout, rx.wait_for(Option::is_some))
            .await
            .map_err(|_| Error::Timeout(ready_timeout))?
            .map_err(|_| Error::Protocol("idle probe stopped".into()))?;
        Ok(IdleProbe { rx, armed, task })
    }

    pub fn current(&self) -> u32 {
        self.rx.borrow().map_or(0, |seen| seen.exists)
    }

    pub fn arm(&self, at_least: u32) {
        self.armed.want.store(at_least, Ordering::Relaxed);
        self.armed.notify.notify_one();
    }

    pub async fn wait_for(&mut self, at_least: u32, timeout: Duration) -> Result<Seen> {
        let value = tokio::time::timeout(
            timeout,
            self.rx
                .wait_for(|v| v.is_some_and(|seen| seen.exists >= at_least)),
        )
        .await
        .map_err(|_| Error::Timeout(timeout))?
        .map_err(|_| Error::Protocol("idle probe stopped".into()))?;
        value.ok_or_else(|| Error::Protocol("idle probe without value".into()))
    }
}

impl Drop for IdleProbe {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn idle_loop(target: &Target, user: &str, password: &str, tx: &SeenTx) -> Result<()> {
    let mut timer = Timer::start();
    let mut client =
        ImapClient::connect_login(target.imap, &target.tls, user, password, &mut timer).await?;
    client.setup().await?;
    let summary = client.run("SELECT INBOX", "SELECT").await?;
    let exists = summary.exists.unwrap_or(0);
    tx.send_replace(Some(Seen {
        exists,
        at: Instant::now(),
        rtt_us: 0,
    }));
    loop {
        let tag = client.idle_start().await?;
        let started = Instant::now();
        loop {
            let (exists, at) = client.idle_next_exists().await?;
            tx.send_replace(Some(Seen {
                exists,
                at,
                rtt_us: 0,
            }));
            if started.elapsed() > REIDLE_AFTER {
                break;
            }
        }
        let summary = client.idle_done(tag).await?;
        if let Some(exists) = summary.exists {
            tx.send_replace(Some(Seen {
                exists,
                at: Instant::now(),
                rtt_us: 0,
            }));
        }
    }
}

async fn poll_loop(
    target: &Target,
    user: &str,
    password: &str,
    tx: &SeenTx,
    armed: &Arm,
    gap: Duration,
    check: Check,
) -> Result<()> {
    let mut timer = Timer::start();
    let mut client =
        ImapClient::connect_login(target.imap, &target.tls, user, password, &mut timer).await?;
    client.setup().await?;
    let mut exists = match check {
        Check::Noop => client.run("SELECT INBOX", "SELECT").await?.exists,
        Check::Status => client.run(STATUS_INBOX, "STATUS").await?.status_messages,
    }
    .unwrap_or(0);
    tx.send_replace(Some(Seen {
        exists,
        at: Instant::now(),
        rtt_us: 0,
    }));
    loop {
        armed.notify.notified().await;
        let mut rtt_us = 0;
        let mut at = Instant::now();
        while exists < armed.want.load(Ordering::Relaxed) {
            if !gap.is_zero() {
                tokio::time::sleep(gap).await;
            }
            let sent = Instant::now();
            let summary = match check {
                Check::Noop => client.run("NOOP", "NOOP").await?,
                Check::Status => client.run(STATUS_INBOX, "STATUS").await?,
            };
            at = Instant::now();
            rtt_us = micros(at.saturating_duration_since(sent));
            let seen = match check {
                Check::Noop => summary.exists,
                Check::Status => summary.status_messages,
            };
            if let Some(now) = seen {
                exists = now;
            }
        }
        tx.send_replace(Some(Seen { exists, at, rtt_us }));
    }
}

#[derive(Clone, Copy)]
enum Check {
    Noop,
    Status,
}

const STATUS_INBOX: &str = "STATUS INBOX (MESSAGES)";

type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<Instant>>>>;

pub struct SinkProbe {
    pub addr: SocketAddr,
    pending: Pending,
    task: JoinHandle<()>,
}

impl SinkProbe {
    pub async fn start(local_ip: IpAddr, port: u16) -> Result<Self> {
        let socket = UdpSocket::bind((IpAddr::from([0, 0, 0, 0]), port)).await?;
        let addr = SocketAddr::new(local_ip, socket.local_addr()?.port());
        let pending: Pending = Arc::default();
        let map = pending.clone();
        let task = tokio::spawn(async move {
            let mut buf = [0u8; 64];
            loop {
                let Ok((len, _)) = socket.recv_from(&mut buf).await else {
                    continue;
                };
                let at = Instant::now();
                let Some(token) = buf
                    .get(..len)
                    .and_then(|b| std::str::from_utf8(b).ok())
                    .and_then(|s| s.trim().parse::<u64>().ok())
                else {
                    continue;
                };
                let sender = map.lock().unwrap_or_else(|e| e.into_inner()).remove(&token);
                if let Some(sender) = sender {
                    let _ = sender.send(at);
                }
            }
        });
        Ok(SinkProbe {
            addr,
            pending,
            task,
        })
    }

    pub fn register(&self, token: u64) -> oneshot::Receiver<Instant> {
        let (tx, rx) = oneshot::channel();
        self.pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(token, tx);
        rx
    }

    pub fn forget(&self, token: u64) {
        self.pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&token);
    }
}

impl Drop for SinkProbe {
    fn drop(&mut self) {
        self.task.abort();
    }
}

pub async fn local_ip_towards(remote: SocketAddr) -> Result<IpAddr> {
    let socket = UdpSocket::bind((IpAddr::from([0, 0, 0, 0]), 0)).await?;
    socket.connect(remote).await?;
    Ok(socket.local_addr()?.ip())
}
