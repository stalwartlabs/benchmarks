mod parse;

use std::fmt::Write as _;
use std::net::SocketAddr;
use std::time::Instant;

use crate::error::{Error, Result};
use crate::net::{Conn, TlsClient};
use crate::stats::{Phase, Timer};

pub use parse::{ListEntry, quote};
use parse::{
    count_numbers, has_resp_code, list_name, literal_len, parse_u64, resp_code_second,
    resp_code_value, status_messages, tokens, trim_crlf,
};

#[derive(Default, Clone, Copy, Debug)]
pub struct Capabilities {
    pub literal_plus: bool,
    pub literal_minus: bool,
    pub qresync: bool,
    pub condstore: bool,
    pub move_ext: bool,
    pub uidplus: bool,
    pub idle: bool,
}

const LITERAL_MINUS_MAX: usize = 4096;

#[derive(Default, Debug)]
pub struct Summary {
    pub exists: Option<u32>,
    pub fetches: u32,
    pub numbers: u32,
    pub expunged: u32,
    pub vanished: u32,
    pub uidvalidity: Option<u64>,
    pub highestmodseq: Option<u64>,
    pub uidnext: Option<u64>,
    pub status_messages: Option<u32>,
    pub appenduid: Option<u64>,
    pub max_uid: Option<u64>,
    pub list: Vec<ListEntry>,
    pub literals: Vec<Vec<u8>>,
    pub already_exists: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Capture {
    None,
    Literals,
}

pub struct ImapClient {
    conn: Conn,
    tag: u32,
    cmd: Vec<u8>,
    line: Vec<u8>,
    pub caps: Capabilities,
    pub delimiter: u8,
}

enum Completion {
    Ok,
    No,
    Bad,
}

impl ImapClient {
    pub async fn connect(addr: SocketAddr, tls: &TlsClient, timer: &mut Timer) -> Result<Self> {
        let mut conn = Conn::connect(addr).await?;
        timer.mark(Phase::Connect);
        conn.upgrade_tls(tls).await?;
        timer.mark(Phase::Tls);
        let mut client = ImapClient {
            conn,
            tag: 0,
            cmd: Vec::with_capacity(256),
            line: Vec::with_capacity(256),
            caps: Capabilities::default(),
            delimiter: b'/',
        };
        let greeting = client.conn.read_line().await?;
        if !greeting.starts_with(b"* OK") {
            return Err(Error::protocol("IMAP greeting", greeting));
        }
        timer.mark(Phase::Greeting);
        Ok(client)
    }

    pub async fn login(&mut self, user: &str, password: &str, timer: &mut Timer) -> Result<()> {
        let mut args = Vec::with_capacity(user.len() + password.len() + 16);
        args.extend_from_slice(b"LOGIN ");
        quote(&mut args, user);
        args.push(b' ');
        quote(&mut args, password);
        self.run_raw(&args, "LOGIN", Capture::None).await?;
        timer.mark(Phase::Auth);
        Ok(())
    }

    pub async fn connect_login(
        addr: SocketAddr,
        tls: &TlsClient,
        user: &str,
        password: &str,
        timer: &mut Timer,
    ) -> Result<Self> {
        let mut client = ImapClient::connect(addr, tls, timer).await?;
        client.login(user, password, timer).await?;
        Ok(client)
    }

    pub async fn setup(&mut self) -> Result<()> {
        let summary = self.run("CAPABILITY", "CAPABILITY").await?;
        drop(summary);
        let summary = self.run("LIST \"\" \"\"", "LIST").await?;
        if let Some(entry) = summary.list.first()
            && entry.delimiter != 0
        {
            self.delimiter = entry.delimiter;
        }
        if self.caps.qresync {
            self.run("ENABLE QRESYNC", "ENABLE").await?;
        } else if self.caps.condstore {
            self.run("ENABLE CONDSTORE", "ENABLE").await?;
        }
        Ok(())
    }

    pub fn folder_name(&self, name: &str) -> String {
        if self.delimiter == b'/' {
            name.to_string()
        } else {
            name.replace('/', &char::from(self.delimiter).to_string())
        }
    }

    pub async fn run(&mut self, command: &str, label: &'static str) -> Result<Summary> {
        self.run_raw(command.as_bytes(), label, Capture::None).await
    }

    pub async fn run_capture(&mut self, command: &str, label: &'static str) -> Result<Summary> {
        self.run_raw(command.as_bytes(), label, Capture::Literals)
            .await
    }

    fn start_command(&mut self, command: &[u8]) -> u32 {
        self.tag += 1;
        self.cmd.clear();
        let _ = write!(TagWriter(&mut self.cmd), "A{} ", self.tag);
        self.cmd.extend_from_slice(command);
        self.tag
    }

    pub async fn run_raw(
        &mut self,
        command: &[u8],
        label: &'static str,
        capture: Capture,
    ) -> Result<Summary> {
        let tag = self.start_command(command);
        self.cmd.extend_from_slice(b"\r\n");
        self.conn.write_all(&self.cmd).await?;
        let mut summary = Summary::default();
        self.read_until_tagged(tag, label, capture, &mut summary)
            .await?;
        Ok(summary)
    }

    pub async fn append(
        &mut self,
        folder: &str,
        flags: &str,
        date: Option<&str>,
        message: &[u8],
    ) -> Result<Summary> {
        let mut args = Vec::with_capacity(folder.len() + 64);
        self.append_prefix(&mut args, folder, flags, date);
        let tag = self.start_command(&args);
        let non_sync = self.non_sync_literal(message.len());
        let _ = write!(
            TagWriter(&mut self.cmd),
            "{{{}{}}}\r\n",
            message.len(),
            if non_sync { "+" } else { "" }
        );
        let mut summary = Summary::default();
        if non_sync {
            let cmd = std::mem::take(&mut self.cmd);
            let result = self.conn.write_parts(&[&cmd, message, b"\r\n"]).await;
            self.cmd = cmd;
            result?;
        } else {
            self.conn.write_all(&self.cmd).await?;
            self.wait_continuation(tag, "APPEND", &mut summary).await?;
            self.conn.write_parts(&[message, b"\r\n"]).await?;
        }
        self.read_until_tagged(tag, "APPEND", Capture::None, &mut summary)
            .await?;
        Ok(summary)
    }

    pub async fn append_pipelined(
        &mut self,
        folder: &str,
        batch: &[(String, Option<String>, Vec<u8>)],
    ) -> Result<u32> {
        if batch.is_empty() {
            return Ok(0);
        }
        if !self.caps.literal_plus {
            for (flags, date, message) in batch {
                self.append(folder, flags, date.as_deref(), message).await?;
            }
            return Ok(batch.len() as u32);
        }
        let mut out = Vec::with_capacity(batch.iter().map(|(_, _, m)| m.len() + 128).sum());
        let first_tag = self.tag + 1;
        let mut args = Vec::with_capacity(128);
        for (flags, date, message) in batch {
            args.clear();
            self.append_prefix(&mut args, folder, flags, date.as_deref());
            self.tag += 1;
            let _ = write!(TagWriter(&mut out), "A{} ", self.tag);
            out.extend_from_slice(&args);
            let _ = write!(TagWriter(&mut out), "{{{}+}}\r\n", message.len());
            out.extend_from_slice(message);
            out.extend_from_slice(b"\r\n");
        }
        self.conn.write_all(&out).await?;
        let mut summary = Summary::default();
        for tag in first_tag..=self.tag {
            self.read_until_tagged(tag, "APPEND", Capture::None, &mut summary)
                .await?;
        }
        Ok(batch.len() as u32)
    }

    fn append_prefix(&self, args: &mut Vec<u8>, folder: &str, flags: &str, date: Option<&str>) {
        args.extend_from_slice(b"APPEND ");
        quote(args, &self.folder_name(folder));
        args.extend_from_slice(b" (");
        args.extend_from_slice(flags.as_bytes());
        args.extend_from_slice(b") ");
        if let Some(date) = date {
            args.extend_from_slice(date.as_bytes());
            args.push(b' ');
        }
    }

    fn non_sync_literal(&self, len: usize) -> bool {
        self.caps.literal_plus || (self.caps.literal_minus && len <= LITERAL_MINUS_MAX)
    }

    async fn wait_continuation(
        &mut self,
        tag: u32,
        label: &'static str,
        summary: &mut Summary,
    ) -> Result<()> {
        loop {
            if self.read_response(Capture::None, summary).await? {
                return Ok(());
            }
            if let Some(result) = self.tagged_result(tag) {
                result?;
                return Err(Error::protocol(label, &self.line));
            }
        }
    }

    async fn read_until_tagged(
        &mut self,
        tag: u32,
        label: &'static str,
        capture: Capture,
        summary: &mut Summary,
    ) -> Result<()> {
        loop {
            self.read_response(capture, summary).await?;
            if let Some(result) = self.tagged_result(tag) {
                return match result? {
                    Completion::Ok => {
                        let text = &self.line;
                        if let Some(uid) = resp_code_second(text, b"APPENDUID") {
                            summary.appenduid = Some(uid);
                        }
                        Ok(())
                    }
                    Completion::No => {
                        summary.already_exists = has_resp_code(&self.line, b"ALREADYEXISTS");
                        Err(Error::rejected(label, &self.line))
                    }
                    Completion::Bad => Err(Error::rejected(label, &self.line)),
                };
            }
        }
    }

    fn tagged_result(&self, tag: u32) -> Option<Result<Completion>> {
        let rest = self.line.strip_prefix(b"A")?;
        let mut parts = rest.splitn(3, |b| *b == b' ');
        let got = parse_u64(parts.next()?)?;
        if got != u64::from(tag) {
            return Some(Err(Error::protocol("unexpected tag", &self.line)));
        }
        let status = parts.next()?;
        Some(Ok(if status.eq_ignore_ascii_case(b"OK") {
            Completion::Ok
        } else if status.eq_ignore_ascii_case(b"NO") {
            Completion::No
        } else {
            Completion::Bad
        }))
    }

    async fn read_response(&mut self, capture: Capture, summary: &mut Summary) -> Result<bool> {
        self.line.clear();
        loop {
            let line = self.conn.read_line().await?;
            let text = trim_crlf(line);
            self.line.extend_from_slice(text);
            match literal_len(text) {
                Some(len) => {
                    if capture == Capture::Literals {
                        let mut data = Vec::with_capacity(len.min(64 * 1024 * 1024));
                        self.conn.read_exact_into(len, Some(&mut data)).await?;
                        summary.literals.push(data);
                    } else {
                        self.conn.read_exact_into(len, None).await?;
                    }
                }
                None => break,
            }
        }
        if self.line.starts_with(b"+") {
            return Ok(true);
        }
        if let Some(rest) = self.line.strip_prefix(b"* ") {
            parse_untagged(rest, summary, &mut self.caps);
        }
        Ok(false)
    }

    pub async fn idle_start(&mut self) -> Result<u32> {
        let tag = self.start_command(b"IDLE");
        self.cmd.extend_from_slice(b"\r\n");
        self.conn.write_all(&self.cmd).await?;
        let mut summary = Summary::default();
        self.wait_continuation(tag, "IDLE", &mut summary).await?;
        Ok(tag)
    }

    pub async fn idle_next_exists(&mut self) -> Result<(u32, Instant)> {
        let mut summary = Summary::default();
        loop {
            self.read_response(Capture::None, &mut summary).await?;
            if let Some(exists) = summary.exists {
                return Ok((exists, Instant::now()));
            }
            if self.line.starts_with(b"* BYE") {
                return Err(Error::protocol("server closed IDLE", &self.line));
            }
        }
    }

    pub async fn idle_done(&mut self, tag: u32) -> Result<Summary> {
        self.conn.write_all(b"DONE\r\n").await?;
        let mut summary = Summary::default();
        self.read_until_tagged(tag, "IDLE", Capture::None, &mut summary)
            .await?;
        Ok(summary)
    }

    pub async fn logout(mut self) -> Result<()> {
        self.run("LOGOUT", "LOGOUT").await?;
        self.conn.shutdown().await;
        Ok(())
    }
}

fn parse_untagged(rest: &[u8], summary: &mut Summary, caps: &mut Capabilities) {
    let mut parts = rest.splitn(2, |b| *b == b' ');
    let Some(first) = parts.next() else {
        return;
    };
    let tail = parts.next().unwrap_or_default().trim_ascii_start();
    if let Some(number) = parse_u64(first) {
        let keyword = tail.split(|b| *b == b' ').next().unwrap_or_default();
        let number = u32::try_from(number).unwrap_or(u32::MAX);
        hashify::fnc_map_ignore_case!(keyword,
            "EXISTS" => { summary.exists = Some(number); },
            "FETCH" => {
                summary.fetches += 1;
                if let Some(uid) = fetch_uid(tail) {
                    summary.max_uid = Some(summary.max_uid.map_or(uid, |m| m.max(uid)));
                }
            },
            "EXPUNGE" => { summary.expunged += 1; },
            _ => {}
        );
        return;
    }
    hashify::fnc_map_ignore_case!(first,
        "OK" => {
            if let Some(v) = resp_code_value(tail, b"UIDVALIDITY") {
                summary.uidvalidity = Some(v);
            } else if let Some(v) = resp_code_value(tail, b"HIGHESTMODSEQ") {
                summary.highestmodseq = Some(v);
            } else if let Some(v) = resp_code_value(tail, b"UIDNEXT") {
                summary.uidnext = Some(v);
            } else if has_resp_code(tail, b"CAPABILITY") {
                parse_capabilities(tail, caps);
            }
        },
        "SEARCH" => { summary.numbers += count_search(tail); },
        "SORT" => { summary.numbers += count_numbers(tail); },
        "THREAD" => { summary.numbers += count_numbers(tail); },
        "ESEARCH" => { summary.numbers += esearch_count(tail); },
        "LIST" => {
            if let Some(entry) = list_name(tail) {
                summary.list.push(entry);
            }
        },
        "STATUS" => { summary.status_messages = status_messages(tail); },
        "VANISHED" => { summary.vanished += count_set(tail); },
        "CAPABILITY" => { parse_capabilities(tail, caps); },
        _ => {}
    );
}

fn fetch_uid(text: &[u8]) -> Option<u64> {
    let mut parts = text
        .split(|b| *b == b' ' || *b == b'(' || *b == b')')
        .filter(|t| !t.is_empty());
    while let Some(token) = parts.next() {
        if token.eq_ignore_ascii_case(b"UID") {
            return parts.next().and_then(parse_u64);
        }
    }
    None
}

fn count_search(text: &[u8]) -> u32 {
    let text = text.split(|b| *b == b'(').next().unwrap_or_default();
    count_numbers(text)
}

fn esearch_count(text: &[u8]) -> u32 {
    let mut parts = tokens(text);
    while let Some(token) = parts.next() {
        if token.eq_ignore_ascii_case(b"COUNT") {
            return parts
                .next()
                .and_then(parse_u64)
                .and_then(|v| u32::try_from(v).ok())
                .unwrap_or(0);
        }
        if token.eq_ignore_ascii_case(b"ALL") {
            return parts.next().map_or(0, count_set_token);
        }
    }
    0
}

fn count_set(text: &[u8]) -> u32 {
    tokens(text)
        .filter(|t| t.first().is_some_and(u8::is_ascii_digit))
        .map(count_set_token)
        .sum()
}

fn count_set_token(token: &[u8]) -> u32 {
    token
        .split(|b| *b == b',')
        .map(|range| {
            let mut ends = range.splitn(2, |b| *b == b':');
            let lo = ends.next().and_then(parse_u64).unwrap_or(0);
            match ends.next().and_then(parse_u64) {
                Some(hi) => (hi.max(lo) - hi.min(lo) + 1) as u32,
                None => u32::from(lo > 0),
            }
        })
        .sum()
}

fn parse_capabilities(text: &[u8], caps: &mut Capabilities) {
    let text = text.strip_prefix(b"[").unwrap_or(text);
    for token in tokens(text) {
        let token = token.strip_suffix(b"]").unwrap_or(token);
        hashify::fnc_map_ignore_case!(token,
            "LITERAL+" => { caps.literal_plus = true; },
            "LITERAL-" => { caps.literal_minus = true; },
            "QRESYNC" => { caps.qresync = true; },
            "CONDSTORE" => { caps.condstore = true; },
            "MOVE" => { caps.move_ext = true; },
            "UIDPLUS" => { caps.uidplus = true; },
            "IDLE" => { caps.idle = true; },
            _ => {}
        );
    }
}

struct TagWriter<'a>(&'a mut Vec<u8>);

impl std::fmt::Write for TagWriter<'_> {
    fn write_str(&mut self, s: &str) -> std::fmt::Result {
        self.0.extend_from_slice(s.as_bytes());
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn untagged() {
        let mut s = Summary::default();
        let mut caps = Capabilities::default();
        parse_untagged(b"172 EXISTS", &mut s, &mut caps);
        parse_untagged(b"OK [UIDVALIDITY 3857529045] UIDs valid", &mut s, &mut caps);
        parse_untagged(b"OK [HIGHESTMODSEQ 99]", &mut s, &mut caps);
        parse_untagged(b"SEARCH 2 84 882 (MODSEQ 917162500)", &mut s, &mut caps);
        parse_untagged(b"12 FETCH (FLAGS (\\Seen) UID 4827313)", &mut s, &mut caps);
        parse_untagged(b"VANISHED (EARLIER) 41,43:116,118", &mut s, &mut caps);
        parse_untagged(
            b"CAPABILITY IMAP4rev1 LITERAL+ IDLE MOVE QRESYNC",
            &mut s,
            &mut caps,
        );
        assert_eq!(s.exists, Some(172));
        assert_eq!(s.uidvalidity, Some(3_857_529_045));
        assert_eq!(s.highestmodseq, Some(99));
        assert_eq!(s.numbers, 3);
        assert_eq!(s.fetches, 1);
        assert_eq!(s.max_uid, Some(4_827_313));
        assert_eq!(s.vanished, 1 + 74 + 1);
        assert!(caps.literal_plus && caps.idle && caps.move_ext && caps.qresync);
        assert_eq!(esearch_count(b"(TAG \"A1\") COUNT 17"), 17);
        assert_eq!(esearch_count(b"(TAG \"A1\") UID ALL 1:5,9"), 6);
    }
}
