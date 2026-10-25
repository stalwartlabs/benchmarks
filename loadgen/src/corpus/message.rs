use std::fmt::Write;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};

use super::Corpus;
use super::UnixTime;
use super::text::write_text;
use crate::rng::Rng;

const BASE64_LINE: usize = 76;
const BASE64_RAW_LINE: usize = BASE64_LINE / 4 * 3;
const BUCKET_TEXT_PART: usize = 4096;
const MULTIPART_OVERHEAD: usize = 400;
const MIN_TEXT: usize = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Deserialize, Serialize)]
pub enum SizeBucket {
    #[serde(rename = "4k")]
    K4,
    #[serde(rename = "64k")]
    K64,
    #[serde(rename = "1m")]
    M1,
}

impl SizeBucket {
    pub const ALL: [SizeBucket; 3] = [SizeBucket::K4, SizeBucket::K64, SizeBucket::M1];

    pub fn bytes(self) -> usize {
        match self {
            SizeBucket::K4 => 4 * 1024,
            SizeBucket::K64 => 64 * 1024,
            SizeBucket::M1 => 1024 * 1024,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Attachment {
    pub bytes: usize,
}

#[derive(Clone, Copy, Debug)]
pub enum BodySpec {
    Text {
        bytes: usize,
    },
    TextWithAttachment {
        bytes: usize,
        attachment: Attachment,
    },
    Bucket(SizeBucket),
}

pub struct MessageSpec<'a> {
    pub from_name: &'a str,
    pub from: &'a str,
    pub to: &'a str,
    pub subject: &'a str,
    pub date: UnixTime,
    pub message_id: &'a str,
    pub in_reply_to: Option<&'a str>,
    pub references: &'a str,
    pub extra_headers: &'a [(&'a str, &'a str)],
    pub body: BodySpec,
    pub body_seed: u64,
}

impl MessageSpec<'_> {
    pub fn write(&self, corpus: &Corpus, out: &mut Vec<u8>) {
        let start = out.len();
        let mut head = String::with_capacity(512);
        let _ = write!(
            head,
            "From: \"{}\" <{}>\r\nTo: {}\r\nSubject: {}\r\nDate: ",
            self.from_name, self.from, self.to, self.subject
        );
        self.date.write_rfc5322(&mut head);
        let _ = write!(head, "\r\nMessage-ID: <{}>\r\n", self.message_id);
        if let Some(parent) = self.in_reply_to {
            let _ = write!(
                head,
                "In-Reply-To: <{parent}>\r\nReferences: {}\r\n",
                self.references
            );
        }
        for (name, value) in self.extra_headers {
            let _ = write!(head, "{name}: {value}\r\n");
        }
        head.push_str("MIME-Version: 1.0\r\n");
        out.extend_from_slice(head.as_bytes());

        let mut rng = Rng::new(self.body_seed);
        match self.body {
            BodySpec::Text { bytes } => {
                write_plain(corpus, &mut rng, bytes.max(MIN_TEXT), out);
            }
            BodySpec::TextWithAttachment { bytes, attachment } => {
                write_multipart(corpus, &mut rng, bytes.max(MIN_TEXT), attachment.bytes, out);
            }
            BodySpec::Bucket(bucket) => {
                let used = out.len() - start;
                let remaining = bucket.bytes().saturating_sub(used);
                match bucket {
                    SizeBucket::K4 | SizeBucket::K64 => {
                        write_plain_exact(corpus, &mut rng, remaining, out);
                    }
                    SizeBucket::M1 => {
                        let encoded =
                            remaining.saturating_sub(BUCKET_TEXT_PART + MULTIPART_OVERHEAD);
                        let raw = encoded / (BASE64_LINE + 2) * BASE64_RAW_LINE;
                        write_multipart(corpus, &mut rng, BUCKET_TEXT_PART, raw, out);
                    }
                }
            }
        }
    }
}

fn write_plain(corpus: &Corpus, rng: &mut Rng, bytes: usize, out: &mut Vec<u8>) {
    out.extend_from_slice(
        b"Content-Type: text/plain; charset=us-ascii\r\nContent-Transfer-Encoding: 7bit\r\n\r\n",
    );
    write_text(&corpus.vocab, rng, bytes, out);
}

fn write_plain_exact(corpus: &Corpus, rng: &mut Rng, total: usize, out: &mut Vec<u8>) {
    let header: &[u8] =
        b"Content-Type: text/plain; charset=us-ascii\r\nContent-Transfer-Encoding: 7bit\r\n\r\n";
    out.extend_from_slice(header);
    let body_start = out.len();
    let target = total.saturating_sub(header.len()).max(MIN_TEXT);
    write_text(&corpus.vocab, rng, target, out);
    out.truncate(body_start + target.saturating_sub(2));
    if let Some(last) = out.last_mut()
        && (*last == b'\r' || *last == b'\n' || *last == b' ')
    {
        *last = b'x';
    }
    out.extend_from_slice(b"\r\n");
}

fn write_multipart(
    corpus: &Corpus,
    rng: &mut Rng,
    text_bytes: usize,
    attachment_bytes: usize,
    out: &mut Vec<u8>,
) {
    let boundary = format!("=_mb_{:016x}", rng.next_u64());
    let mut part = String::with_capacity(256);
    let _ = write!(
        part,
        "Content-Type: multipart/mixed; boundary=\"{boundary}\"\r\n\r\nThis is a multi-part message in MIME format.\r\n\r\n--{boundary}\r\nContent-Type: text/plain; charset=us-ascii\r\nContent-Transfer-Encoding: 7bit\r\n\r\n"
    );
    out.extend_from_slice(part.as_bytes());
    write_text(&corpus.vocab, rng, text_bytes, out);
    part.clear();
    let _ = write!(
        part,
        "\r\n--{boundary}\r\nContent-Type: application/octet-stream; name=\"attachment-{:08x}.bin\"\r\nContent-Disposition: attachment; filename=\"attachment-{:08x}.bin\"\r\nContent-Transfer-Encoding: base64\r\n\r\n",
        rng.next_u64() as u32,
        rng.next_u64() as u32
    );
    out.extend_from_slice(part.as_bytes());
    let mut raw = vec![0u8; attachment_bytes];
    rng.fill_bytes(&mut raw);
    let encoded = STANDARD.encode(&raw);
    out.reserve(encoded.len() + encoded.len() / BASE64_LINE * 2 + 64);
    for line in encoded.as_bytes().chunks(BASE64_LINE) {
        out.extend_from_slice(line);
        out.extend_from_slice(b"\r\n");
    }
    part.clear();
    let _ = write!(part, "\r\n--{boundary}--\r\n");
    out.extend_from_slice(part.as_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(body: BodySpec) -> MessageSpec<'static> {
        MessageSpec {
            from_name: "Alice Example",
            from: "alice@example.net",
            to: "user0001@example.org",
            subject: "Status report",
            date: UnixTime(1_700_000_000),
            message_id: "m1@example.org",
            in_reply_to: None,
            references: "",
            extra_headers: &[],
            body,
            body_seed: 42,
        }
    }

    #[test]
    fn buckets_have_expected_size() {
        let corpus = Corpus::new(None).expect("corpus");
        for bucket in SizeBucket::ALL {
            let mut out = Vec::new();
            spec(BodySpec::Bucket(bucket)).write(&corpus, &mut out);
            let target = bucket.bytes() as f64;
            let ratio = out.len() as f64 / target;
            assert!(
                (0.98..=1.01).contains(&ratio),
                "{bucket:?} {} {ratio}",
                out.len()
            );
            assert!(out.ends_with(b"\r\n"));
        }
    }

    #[test]
    fn deterministic_output() {
        let corpus = Corpus::new(None).expect("corpus");
        let mut a = Vec::new();
        let mut b = Vec::new();
        let body = BodySpec::TextWithAttachment {
            bytes: 2000,
            attachment: Attachment { bytes: 10_000 },
        };
        spec(body).write(&corpus, &mut a);
        spec(body).write(&corpus, &mut b);
        assert_eq!(a, b);
        assert!(memchr::memmem::find(&a, b"\r\n.").is_none());
        assert!(
            a.iter()
                .all(|c| *c == b'\r' || *c == b'\n' || (0x20..0x7f).contains(c))
        );
    }
}
