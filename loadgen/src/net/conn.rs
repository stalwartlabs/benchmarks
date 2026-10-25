use std::io;
use std::net::SocketAddr;
use std::pin::Pin;
use std::task::{Context, Poll};

use memchr::memchr;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::net::TcpStream;
use tokio_rustls::client::TlsStream;

use super::TlsClient;
use crate::error::{Error, Result};

const READ_CHUNK: usize = 64 * 1024;
const MAX_LINE: usize = 16 * 1024 * 1024;

pub enum Stream {
    Plain(TcpStream),
    Tls(Box<TlsStream<TcpStream>>),
}

impl AsyncRead for Stream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        match self.get_mut() {
            Stream::Plain(s) => Pin::new(s).poll_read(cx, buf),
            Stream::Tls(s) => Pin::new(s.as_mut()).poll_read(cx, buf),
        }
    }
}

impl AsyncWrite for Stream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        match self.get_mut() {
            Stream::Plain(s) => Pin::new(s).poll_write(cx, buf),
            Stream::Tls(s) => Pin::new(s.as_mut()).poll_write(cx, buf),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            Stream::Plain(s) => Pin::new(s).poll_flush(cx),
            Stream::Tls(s) => Pin::new(s.as_mut()).poll_flush(cx),
        }
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            Stream::Plain(s) => Pin::new(s).poll_shutdown(cx),
            Stream::Tls(s) => Pin::new(s.as_mut()).poll_shutdown(cx),
        }
    }
}

pub struct Conn {
    stream: Option<Stream>,
    buf: Vec<u8>,
    start: usize,
    end: usize,
    pub bytes_read: u64,
}

impl Conn {
    pub async fn connect(addr: SocketAddr) -> Result<Self> {
        let tcp = TcpStream::connect(addr).await?;
        tcp.set_nodelay(true)?;
        Ok(Conn::new(Stream::Plain(tcp)))
    }

    pub fn new(stream: Stream) -> Self {
        Conn {
            stream: Some(stream),
            buf: vec![0; READ_CHUNK],
            start: 0,
            end: 0,
            bytes_read: 0,
        }
    }

    fn stream(&mut self) -> Result<&mut Stream> {
        self.stream
            .as_mut()
            .ok_or_else(|| Error::Protocol("connection closed".into()))
    }

    pub async fn upgrade_tls(&mut self, tls: &TlsClient) -> Result<()> {
        if self.start != self.end {
            return Err(Error::Protocol(
                "unexpected data before TLS handshake".into(),
            ));
        }
        match self.stream.take() {
            Some(Stream::Plain(tcp)) => {
                self.stream = Some(Stream::Tls(Box::new(tls.handshake(tcp).await?)));
                Ok(())
            }
            Some(other) => {
                self.stream = Some(other);
                Err(Error::Protocol("TLS already active".into()))
            }
            None => Err(Error::Protocol("connection closed".into())),
        }
    }

    pub async fn write_all(&mut self, data: &[u8]) -> Result<()> {
        let stream = self.stream()?;
        stream.write_all(data).await?;
        stream.flush().await?;
        Ok(())
    }

    pub async fn write_parts(&mut self, parts: &[&[u8]]) -> Result<()> {
        let stream = self.stream()?;
        for part in parts {
            stream.write_all(part).await?;
        }
        stream.flush().await?;
        Ok(())
    }

    pub async fn shutdown(&mut self) {
        if let Some(stream) = self.stream.as_mut() {
            let _ = stream.shutdown().await;
        }
        self.stream = None;
    }

    async fn fill(&mut self) -> Result<()> {
        if self.start > 0 {
            self.buf.copy_within(self.start..self.end, 0);
            self.end -= self.start;
            self.start = 0;
        }
        if self.end == self.buf.len() {
            if self.buf.len() >= MAX_LINE {
                return Err(Error::Protocol("line too long".into()));
            }
            let grow = self.buf.len();
            self.buf.resize(self.buf.len() + grow, 0);
        }
        let Conn {
            stream, buf, end, ..
        } = self;
        let stream = stream
            .as_mut()
            .ok_or_else(|| Error::Protocol("connection closed".into()))?;
        let read = stream.read(&mut buf[*end..]).await?;
        if read == 0 {
            return Err(Error::Io(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "connection closed by server",
            )));
        }
        self.end += read;
        self.bytes_read += read as u64;
        Ok(())
    }

    pub async fn read_line(&mut self) -> Result<&[u8]> {
        let mut scanned = 0;
        loop {
            let window = &self.buf[self.start + scanned..self.end];
            if let Some(pos) = memchr(b'\n', window) {
                let line_start = self.start;
                let line_end = self.start + scanned + pos + 1;
                self.start = line_end;
                return Ok(&self.buf[line_start..line_end]);
            }
            scanned = self.end - self.start;
            self.fill().await?;
        }
    }

    pub async fn read_exact_into(
        &mut self,
        mut len: usize,
        mut out: Option<&mut Vec<u8>>,
    ) -> Result<()> {
        while len > 0 {
            if self.start == self.end {
                self.fill().await?;
            }
            let take = len.min(self.end - self.start);
            if let Some(out) = out.as_deref_mut() {
                out.extend_from_slice(&self.buf[self.start..self.start + take]);
            }
            self.start += take;
            len -= take;
        }
        Ok(())
    }
}
