use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use memchr::memmem;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream, UdpSocket};

use crate::error::Result;

pub const PROBE_HEADER: &str = "X-Mailbench-Probe";
const MAX_LINE: usize = 1024 * 1024;

#[derive(Default)]
struct Counters {
    connections: AtomicU64,
    messages: AtomicU64,
    notified: AtomicU64,
}

pub async fn run(listen: SocketAddr, hostname: &str) -> Result<()> {
    let listener = TcpListener::bind(listen).await?;
    let udp = Arc::new(UdpSocket::bind(("0.0.0.0", 0)).await?);
    let counters = Arc::new(Counters::default());
    let banner: Arc<[u8]> = format!("220 {hostname} ESMTP mailbench sink\r\n")
        .into_bytes()
        .into();
    let ehlo: Arc<[u8]> =
        format!("250-{hostname}\r\n250-PIPELINING\r\n250-8BITMIME\r\n250 SIZE 104857600\r\n")
            .into_bytes()
            .into();
    eprintln!("sink listening on {listen}");
    {
        let counters = counters.clone();
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(Duration::from_secs(60));
            loop {
                ticker.tick().await;
                eprintln!(
                    "sink: connections={} messages={} notified={}",
                    counters.connections.load(Ordering::Relaxed),
                    counters.messages.load(Ordering::Relaxed),
                    counters.notified.load(Ordering::Relaxed)
                );
            }
        });
    }
    loop {
        let (stream, _) = listener.accept().await?;
        let _ = stream.set_nodelay(true);
        counters.connections.fetch_add(1, Ordering::Relaxed);
        let session = Session {
            udp: udp.clone(),
            counters: counters.clone(),
            banner: banner.clone(),
            ehlo: ehlo.clone(),
        };
        tokio::spawn(async move {
            let _ = session.serve(stream).await;
        });
    }
}

struct Session {
    udp: Arc<UdpSocket>,
    counters: Arc<Counters>,
    banner: Arc<[u8]>,
    ehlo: Arc<[u8]>,
}

enum Verb {
    Ehlo,
    Helo,
    Mail,
    Rcpt,
    Data,
    Rset,
    Noop,
    Quit,
    Unknown,
}

impl Session {
    async fn serve(self, stream: TcpStream) -> std::io::Result<()> {
        let (read, mut write) = stream.into_split();
        let mut reader = BufReader::with_capacity(64 * 1024, read);
        let mut line = Vec::with_capacity(1024);
        let finder = memmem::Finder::new(PROBE_HEADER.as_bytes());
        write.write_all(&self.banner).await?;
        loop {
            line.clear();
            if reader.read_until(b'\n', &mut line).await? == 0 || line.len() > MAX_LINE {
                return Ok(());
            }
            let verb = line.get(..4).map_or(Verb::Unknown, |v| {
                hashify::tiny_map_ignore_case!(v,
                    "EHLO" => Verb::Ehlo,
                    "HELO" => Verb::Helo,
                    "MAIL" => Verb::Mail,
                    "RCPT" => Verb::Rcpt,
                    "DATA" => Verb::Data,
                    "RSET" => Verb::Rset,
                    "NOOP" => Verb::Noop,
                    "QUIT" => Verb::Quit,
                )
                .unwrap_or(Verb::Unknown)
            });
            match verb {
                Verb::Ehlo => write.write_all(&self.ehlo).await?,
                Verb::Helo => write.write_all(b"250 sink\r\n").await?,
                Verb::Mail | Verb::Rcpt | Verb::Rset | Verb::Noop => {
                    write.write_all(b"250 2.0.0 OK\r\n").await?
                }
                Verb::Quit => {
                    write.write_all(b"221 2.0.0 bye\r\n").await?;
                    return Ok(());
                }
                Verb::Data => {
                    write.write_all(b"354 go ahead\r\n").await?;
                    let mut in_headers = true;
                    let mut probe: Option<Vec<u8>> = None;
                    loop {
                        line.clear();
                        if reader.read_until(b'\n', &mut line).await? == 0 {
                            return Ok(());
                        }
                        if line == b".\r\n" || line == b".\n" {
                            break;
                        }
                        if in_headers {
                            if line == b"\r\n" || line == b"\n" {
                                in_headers = false;
                            } else if probe.is_none() && finder.find(&line).is_some() {
                                probe = Some(line.clone());
                            }
                        }
                    }
                    self.counters.messages.fetch_add(1, Ordering::Relaxed);
                    if let Some(header) = probe {
                        self.notify(&header).await;
                    }
                    write.write_all(b"250 2.0.0 accepted\r\n").await?;
                }
                Verb::Unknown => write.write_all(b"502 5.5.2 not implemented\r\n").await?,
            }
        }
    }

    async fn notify(&self, header: &[u8]) {
        let Some(value) = header.splitn(2, |b| *b == b':').nth(1) else {
            return;
        };
        let value = String::from_utf8_lossy(value);
        let mut parts = value.split_whitespace();
        let (Some(addr), Some(token)) = (parts.next(), parts.next()) else {
            return;
        };
        let Ok(addr) = addr.parse::<SocketAddr>() else {
            return;
        };
        if self.udp.send_to(token.as_bytes(), addr).await.is_ok() {
            self.counters.notified.fetch_add(1, Ordering::Relaxed);
        }
    }
}
