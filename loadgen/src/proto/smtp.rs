use std::net::SocketAddr;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use memchr::memmem;

use crate::error::{Error, Result};
use crate::net::{Conn, TlsClient};
use crate::stats::{Phase, Timer};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Security {
    Starttls,
    Implicit,
}

#[derive(Default, Clone, Copy)]
pub struct Capabilities {
    pub pipelining: bool,
    pub starttls: bool,
}

pub struct SmtpClient {
    conn: Conn,
    caps: Capabilities,
    ehlo: Box<str>,
    buf: Vec<u8>,
}

pub struct Reply {
    pub code: u16,
}

impl SmtpClient {
    pub async fn connect(
        addr: SocketAddr,
        tls: &TlsClient,
        security: Security,
        ehlo: &str,
        timer: &mut Timer,
    ) -> Result<Self> {
        let mut conn = Conn::connect(addr).await?;
        timer.mark(Phase::Connect);
        if security == Security::Implicit {
            conn.upgrade_tls(tls).await?;
            timer.mark(Phase::Tls);
        }
        let mut client = SmtpClient {
            conn,
            caps: Capabilities::default(),
            ehlo: ehlo.into(),
            buf: Vec::with_capacity(512),
        };
        client.expect(220, "greeting").await?;
        client.send_ehlo().await?;
        timer.mark(Phase::Greeting);
        if security == Security::Starttls {
            if !client.caps.starttls {
                return Err(Error::Protocol("server does not offer STARTTLS".into()));
            }
            client.conn.write_all(b"STARTTLS\r\n").await?;
            client.expect(220, "STARTTLS").await?;
            client.conn.upgrade_tls(tls).await?;
            client.send_ehlo().await?;
            timer.mark(Phase::Tls);
        }
        Ok(client)
    }

    async fn send_ehlo(&mut self) -> Result<()> {
        self.buf.clear();
        self.buf.extend_from_slice(b"EHLO ");
        self.buf.extend_from_slice(self.ehlo.as_bytes());
        self.buf.extend_from_slice(b"\r\n");
        self.conn.write_all(&self.buf).await?;
        let mut caps = Capabilities::default();
        loop {
            let line = self.conn.read_line().await?;
            let (code, last, text) = parse_reply_line(line)?;
            if code != 250 {
                return Err(Error::rejected("EHLO", line));
            }
            let keyword = text.split(|b| *b == b' ').next().unwrap_or_default();
            if keyword.eq_ignore_ascii_case(b"PIPELINING") {
                caps.pipelining = true;
            } else if keyword.eq_ignore_ascii_case(b"STARTTLS") {
                caps.starttls = true;
            }
            if last {
                break;
            }
        }
        self.caps = caps;
        Ok(())
    }

    async fn read_reply(&mut self) -> Result<Reply> {
        loop {
            let line = self.conn.read_line().await?;
            let (code, last, _) = parse_reply_line(line)?;
            if last {
                return Ok(Reply { code });
            }
        }
    }

    async fn expect(&mut self, code: u16, command: &'static str) -> Result<()> {
        loop {
            let line = self.conn.read_line().await?;
            let (got, last, _) = parse_reply_line(line)?;
            if got != code {
                return Err(Error::rejected(command, line));
            }
            if last {
                return Ok(());
            }
        }
    }

    pub async fn auth_plain(
        &mut self,
        user: &str,
        password: &str,
        timer: &mut Timer,
    ) -> Result<()> {
        let mut token = Vec::with_capacity(user.len() + password.len() + 2);
        token.push(0);
        token.extend_from_slice(user.as_bytes());
        token.push(0);
        token.extend_from_slice(password.as_bytes());
        self.buf.clear();
        self.buf.extend_from_slice(b"AUTH PLAIN ");
        self.buf
            .extend_from_slice(STANDARD.encode(&token).as_bytes());
        self.buf.extend_from_slice(b"\r\n");
        self.conn.write_all(&self.buf).await?;
        self.expect(235, "AUTH").await?;
        timer.mark(Phase::Auth);
        Ok(())
    }

    pub async fn send(&mut self, from: &str, recipients: &[String], message: &[u8]) -> Result<()> {
        self.buf.clear();
        self.buf.extend_from_slice(b"MAIL FROM:<");
        self.buf.extend_from_slice(from.as_bytes());
        self.buf.extend_from_slice(b">\r\n");
        if self.caps.pipelining {
            for rcpt in recipients {
                push_rcpt(&mut self.buf, rcpt);
            }
            self.buf.extend_from_slice(b"DATA\r\n");
            self.conn.write_all(&self.buf).await?;
            let mail = self.read_reply().await?;
            let mut accepted = 0;
            for _ in recipients {
                if self.read_reply().await?.code == 250 {
                    accepted += 1;
                }
            }
            let data = self.read_reply().await?;
            if mail.code != 250 || accepted != recipients.len() || data.code != 354 {
                if data.code == 354 {
                    self.conn.write_all(b".\r\n").await?;
                    let _ = self.read_reply().await;
                }
                return Err(Error::Rejected {
                    command: "envelope",
                    reply: format!(
                        "MAIL {} accepted {}/{} DATA {}",
                        mail.code,
                        accepted,
                        recipients.len(),
                        data.code
                    ),
                });
            }
        } else {
            self.conn.write_all(&self.buf).await?;
            self.expect(250, "MAIL").await?;
            for rcpt in recipients {
                self.buf.clear();
                push_rcpt(&mut self.buf, rcpt);
                self.conn.write_all(&self.buf).await?;
                self.expect(250, "RCPT").await?;
            }
            self.conn.write_all(b"DATA\r\n").await?;
            self.expect(354, "DATA").await?;
        }
        self.write_data(message).await?;
        self.expect(250, "end of data").await
    }

    async fn write_data(&mut self, message: &[u8]) -> Result<()> {
        if message.starts_with(b".") || memmem::find(message, b"\n.").is_some() {
            let stuffed = dot_stuff(message);
            self.conn.write_all(&stuffed).await?;
        } else {
            self.conn.write_all(message).await?;
        }
        if message.ends_with(b"\r\n") {
            self.conn.write_all(b".\r\n").await
        } else {
            self.conn.write_all(b"\r\n.\r\n").await
        }
    }

    pub async fn quit(mut self) {
        if self.conn.write_all(b"QUIT\r\n").await.is_ok() {
            let _ = self.read_reply().await;
        }
        self.conn.shutdown().await;
    }
}

fn push_rcpt(buf: &mut Vec<u8>, rcpt: &str) {
    buf.extend_from_slice(b"RCPT TO:<");
    buf.extend_from_slice(rcpt.as_bytes());
    buf.extend_from_slice(b">\r\n");
}

#[cold]
fn dot_stuff(message: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(message.len() + 64);
    let mut at_line_start = true;
    for &b in message {
        if at_line_start && b == b'.' {
            out.push(b'.');
        }
        out.push(b);
        at_line_start = b == b'\n';
    }
    out
}

pub fn parse_reply_line(line: &[u8]) -> Result<(u16, bool, &[u8])> {
    let [a, b, c, rest @ ..] = line else {
        return Err(Error::protocol("short SMTP reply", line));
    };
    if !(a.is_ascii_digit() && b.is_ascii_digit() && c.is_ascii_digit()) {
        return Err(Error::protocol("invalid SMTP reply", line));
    }
    let code = u16::from(a - b'0') * 100 + u16::from(b - b'0') * 10 + u16::from(c - b'0');
    let (last, text) = match rest.split_first() {
        Some((b'-', text)) => (false, text),
        Some((_, text)) => (true, text),
        None => (true, rest),
    };
    let text = text
        .strip_suffix(b"\r\n")
        .or_else(|| text.strip_suffix(b"\n"))
        .unwrap_or(text);
    Ok((code, last, text))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reply_lines() {
        let (code, last, text) = parse_reply_line(b"250-PIPELINING\r\n").expect("parse");
        assert_eq!((code, last, text), (250, false, &b"PIPELINING"[..]));
        let (code, last, _) = parse_reply_line(b"354 go ahead\r\n").expect("parse");
        assert_eq!((code, last), (354, true));
        assert!(parse_reply_line(b"2x0 x\r\n").is_err());
    }

    #[test]
    fn stuffing() {
        assert_eq!(dot_stuff(b".a\r\n.b\r\nc.\r\n"), b"..a\r\n..b\r\nc.\r\n");
    }
}
