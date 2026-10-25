use std::net::SocketAddr;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;

use super::{Conn, TlsClient};
use crate::error::{Error, Result};

const MAX_BODY: usize = 512 * 1024 * 1024;

pub struct HttpClient {
    addr: SocketAddr,
    tls: Option<TlsClient>,
    host: Box<str>,
    authorization: Box<str>,
    conn: Option<Conn>,
}

pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}

enum BodyFraming {
    Length(usize),
    Chunked,
    UntilClose,
}

impl HttpClient {
    pub fn new(
        addr: SocketAddr,
        tls: Option<TlsClient>,
        host: &str,
        user: &str,
        secret: &str,
    ) -> Self {
        let token = STANDARD.encode(format!("{user}:{secret}"));
        HttpClient {
            addr,
            tls,
            host: host.into(),
            authorization: format!("Basic {token}").into_boxed_str(),
            conn: None,
        }
    }

    async fn connection(&mut self) -> Result<&mut Conn> {
        if self.conn.is_none() {
            let mut conn = Conn::connect(self.addr).await?;
            if let Some(tls) = &self.tls {
                conn.upgrade_tls(tls).await?;
            }
            self.conn = Some(conn);
        }
        self.conn
            .as_mut()
            .ok_or_else(|| Error::Protocol("no HTTP connection".into()))
    }

    pub async fn request(
        &mut self,
        method: &str,
        path: &str,
        content_type: &str,
        body: &[u8],
    ) -> Result<Response> {
        match self.request_once(method, path, content_type, body).await {
            Ok(response) => Ok(response),
            Err(Error::Io(_)) if self.conn.is_none() => {
                self.request_once(method, path, content_type, body).await
            }
            Err(err) => Err(err),
        }
    }

    async fn request_once(
        &mut self,
        method: &str,
        path: &str,
        content_type: &str,
        body: &[u8],
    ) -> Result<Response> {
        let head = format!(
            "{method} {path} HTTP/1.1\r\nHost: {}\r\nAuthorization: {}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nAccept: application/json\r\n\r\n",
            self.host,
            self.authorization,
            body.len()
        );
        let result = self.exchange(head.as_bytes(), body).await;
        if result.is_err() {
            self.conn = None;
        }
        result
    }

    async fn exchange(&mut self, head: &[u8], body: &[u8]) -> Result<Response> {
        let conn = self.connection().await?;
        conn.write_parts(&[head, body]).await?;
        let status_line = conn.read_line().await?;
        let status = status_line
            .split(|b| *b == b' ')
            .nth(1)
            .and_then(|code| std::str::from_utf8(code).ok())
            .and_then(|code| code.parse::<u16>().ok())
            .ok_or_else(|| Error::protocol("invalid HTTP status line", status_line))?;
        let mut framing = BodyFraming::UntilClose;
        let mut close = false;
        loop {
            let line = conn.read_line().await?;
            let line = trim_crlf(line);
            if line.is_empty() {
                break;
            }
            let Some((name, value)) = split_header(line) else {
                continue;
            };
            if name.eq_ignore_ascii_case(b"content-length") {
                let len = std::str::from_utf8(value)
                    .ok()
                    .and_then(|v| v.parse::<usize>().ok())
                    .ok_or_else(|| Error::protocol("invalid Content-Length", line))?;
                framing = BodyFraming::Length(len);
            } else if name.eq_ignore_ascii_case(b"transfer-encoding")
                && value.eq_ignore_ascii_case(b"chunked")
            {
                framing = BodyFraming::Chunked;
            } else if name.eq_ignore_ascii_case(b"connection")
                && value.eq_ignore_ascii_case(b"close")
            {
                close = true;
            }
        }
        let mut body = Vec::new();
        match framing {
            BodyFraming::Length(len) => {
                if len > MAX_BODY {
                    return Err(Error::Protocol(format!("HTTP body too large: {len}")));
                }
                body.reserve(len);
                conn.read_exact_into(len, Some(&mut body)).await?;
            }
            BodyFraming::Chunked => loop {
                let line = conn.read_line().await?;
                let size_text = trim_crlf(line);
                let size_text = size_text.split(|b| *b == b';').next().unwrap_or_default();
                let size = std::str::from_utf8(size_text)
                    .ok()
                    .and_then(|v| usize::from_str_radix(v.trim(), 16).ok())
                    .ok_or_else(|| Error::protocol("invalid chunk size", size_text))?;
                if size == 0 {
                    loop {
                        if trim_crlf(conn.read_line().await?).is_empty() {
                            break;
                        }
                    }
                    break;
                }
                if body.len() + size > MAX_BODY {
                    return Err(Error::Protocol("HTTP body too large".into()));
                }
                conn.read_exact_into(size, Some(&mut body)).await?;
                conn.read_line().await?;
            },
            BodyFraming::UntilClose => {
                close = true;
                while let Ok(line) = conn.read_line().await {
                    body.extend_from_slice(line);
                }
            }
        }
        if close {
            self.conn = None;
        }
        Ok(Response { status, body })
    }
}

fn trim_crlf(line: &[u8]) -> &[u8] {
    let line = line.strip_suffix(b"\n").unwrap_or(line);
    line.strip_suffix(b"\r").unwrap_or(line)
}

fn split_header(line: &[u8]) -> Option<(&[u8], &[u8])> {
    let mut parts = line.splitn(2, |b| *b == b':');
    Some((parts.next()?.trim_ascii(), parts.next()?.trim_ascii()))
}
