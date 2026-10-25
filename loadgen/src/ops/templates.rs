use std::fmt::Write;

use memchr::memmem;

use crate::corpus::{BodySpec, Corpus, MessageSpec, UnixTime};
use crate::dataset::corpus_body;
use crate::rng::Rng;
use crate::scenario::SizeSpec;

const MIX_TEMPLATES: usize = 1024;
const TEMPLATE_SEED: u64 = 0x7465_6d70;
const MIME_MARKER: &[u8] = b"MIME-Version: 1.0\r\n";

pub struct Templates {
    bodies: Vec<Box<[u8]>>,
}

pub struct Headers<'a> {
    pub from_name: &'a str,
    pub from: &'a str,
    pub to: &'a str,
    pub subject: &'a str,
    pub message_id: &'a str,
    pub date: UnixTime,
    pub probe: Option<&'a str>,
}

impl Templates {
    pub fn new(corpus: &Corpus, size: SizeSpec) -> Self {
        let mut rng = Rng::from_parts(&[TEMPLATE_SEED, size as u64]);
        let specs: Vec<BodySpec> = match size.bucket() {
            Some(bucket) => vec![BodySpec::Bucket(bucket)],
            None => (0..MIX_TEMPLATES).map(|_| corpus_body(&mut rng)).collect(),
        };
        let mut out = Vec::new();
        let bodies = specs
            .into_iter()
            .map(|body| {
                out.clear();
                MessageSpec {
                    from_name: "Template Sender",
                    from: "template@example.com",
                    to: "template@example.org",
                    subject: "template",
                    date: UnixTime(0),
                    message_id: "template@example.org",
                    in_reply_to: None,
                    references: "",
                    extra_headers: &[],
                    body,
                    body_seed: rng.next_u64(),
                }
                .write(corpus, &mut out);
                let body_start =
                    memmem::find(&out, MIME_MARKER).map_or(0, |pos| pos + MIME_MARKER.len());
                out.get(body_start..).unwrap_or_default().into()
            })
            .collect();
        Templates { bodies }
    }

    pub fn write(&self, rng: &mut Rng, headers: &Headers<'_>, out: &mut Vec<u8>) {
        out.clear();
        let body = &self.bodies[rng.below_usize(self.bodies.len())];
        let mut head = String::with_capacity(400);
        let _ = write!(
            head,
            "From: \"{}\" <{}>\r\nTo: {}\r\nSubject: {}\r\nDate: ",
            headers.from_name, headers.from, headers.to, headers.subject
        );
        headers.date.write_rfc5322(&mut head);
        let _ = write!(head, "\r\nMessage-ID: <{}>\r\n", headers.message_id);
        if let Some(probe) = headers.probe {
            let _ = write!(head, "{}: {probe}\r\n", crate::proto::sink::PROBE_HEADER);
        }
        head.push_str("MIME-Version: 1.0\r\n");
        out.reserve(head.len() + body.len());
        out.extend_from_slice(head.as_bytes());
        out.extend_from_slice(body);
    }
}
