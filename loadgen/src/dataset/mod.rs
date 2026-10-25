mod account;
mod preset;

use std::borrow::Cow;
use std::fmt::Write;

pub use preset::{DatasetName, Preset};

use crate::corpus::{Attachment, BodySpec, Corpus, MessageSpec, SizeBucket, UnixTime};
use crate::rng::{Rng, Zipf, mix_all};

pub const DEFAULT_SEED: u64 = 20_261_025;
pub const BUCKETS_FOLDER: &str = "Buckets";
pub const REMOTE_DOMAIN: &str = "example.net";
const CONTACT_DOMAIN: &str = "example.com";
const CONTACTS: usize = 5_000;
const DATASET_END: i64 = 1_761_955_200;
const DATASET_SPAN: i64 = 2 * 365 * 86_400;
const MEDIAN_MESSAGE_BYTES: f64 = 8_192.0;
const MESSAGE_SIGMA: f64 = 0.6;
const HEADER_ESTIMATE: usize = 600;
const ATTACHMENT_RATE: f64 = 0.01;
const REPLY_RATE: f64 = 0.35;
const MAX_PARENT_DISTANCE: u64 = 30;
const MAX_THREAD_DEPTH: usize = 64;
const MAX_REFERENCES: usize = 10;
const INTERNAL_SENDER_RATE: f64 = 0.3;
const INTERNAL_NAME_BASE: u64 = 1 << 40;

const STREAM_RANKS: u64 = 1;
const STREAM_THREAD: u64 = 2;
const STREAM_SUBJECT: u64 = 3;
const STREAM_PEOPLE: u64 = 4;
const STREAM_BODY: u64 = 5;
const STREAM_DATE: u64 = 6;
const STREAM_FLAGS: u64 = 7;
pub(crate) const STREAM_PASSWORD: u64 = 8;

const REGULAR_FOLDERS: &[(&str, FolderKind, f64)] = &[
    ("INBOX", FolderKind::Inbox, 0.0),
    ("Sent", FolderKind::Sent, 0.15),
    ("Archive", FolderKind::Other, 0.20),
    ("Trash", FolderKind::Trash, 0.04),
    ("Lists/Dev", FolderKind::Other, 0.03),
    ("Lists/Announce", FolderKind::Other, 0.02),
    ("Receipts", FolderKind::Other, 0.01),
];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum AccountId {
    Regular(u32),
    Large(u8),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FolderKind {
    Inbox,
    Sent,
    Trash,
    Other,
    Buckets,
}

#[derive(Clone, Debug)]
pub struct FolderPlan {
    pub name: Cow<'static, str>,
    pub kind: FolderKind,
    pub count: u32,
}

pub struct MessageMeta {
    pub date: UnixTime,
    pub seen: bool,
    pub flagged: bool,
}

pub struct Dataset {
    pub seed: u64,
    pub domain: Box<str>,
    preset: Preset,
    sizes: Vec<u32>,
    contacts: Zipf,
    width: usize,
}

impl Dataset {
    pub fn new(name: DatasetName, seed: u64, domain: &str) -> Self {
        let preset = name.preset();
        let sizes = mailbox_sizes(&preset, seed);
        let width = preset.users.to_string().len().max(4);
        Dataset {
            seed,
            domain: domain.into(),
            preset,
            sizes,
            contacts: Zipf::new(CONTACTS, 1.0),
            width,
        }
    }

    pub fn users(&self) -> u32 {
        self.preset.users
    }

    pub fn accounts(&self) -> impl Iterator<Item = AccountId> + '_ {
        (0..self.preset.users)
            .map(AccountId::Regular)
            .chain((0..self.preset.large.len() as u8).map(AccountId::Large))
    }

    pub fn ordinal(&self, account: AccountId) -> u64 {
        match account {
            AccountId::Regular(i) => u64::from(i),
            AccountId::Large(i) => u64::from(self.preset.users) + u64::from(i),
        }
    }

    pub fn find_large(&self, name: &str) -> Option<AccountId> {
        self.preset
            .large
            .iter()
            .position(|spec| spec.name == name)
            .map(|i| AccountId::Large(i as u8))
    }

    pub fn write_local_part(&self, account: AccountId, out: &mut String) {
        match account {
            AccountId::Regular(i) => {
                let _ = write!(out, "user{:0width$}", i + 1, width = self.width);
            }
            AccountId::Large(i) => {
                out.push_str(
                    self.preset
                        .large
                        .get(usize::from(i))
                        .map_or("large", |spec| spec.name),
                );
            }
        }
    }

    pub fn write_address(&self, account: AccountId, out: &mut String) {
        self.write_local_part(account, out);
        out.push('@');
        out.push_str(&self.domain);
    }

    pub fn address(&self, account: AccountId) -> String {
        let mut out = String::with_capacity(32);
        self.write_address(account, &mut out);
        out
    }

    pub fn remote_address(&self, index: u64) -> String {
        format!("rcpt{index:06}@{REMOTE_DOMAIN}")
    }

    pub fn has_buckets(&self, account: AccountId) -> bool {
        match account {
            AccountId::Regular(i) => i < self.preset.bucket_users,
            AccountId::Large(_) => true,
        }
    }

    pub fn total_regular(&self, user: u32) -> u32 {
        self.sizes.get(user as usize).copied().unwrap_or(0)
    }

    pub fn folders(&self, account: AccountId) -> Vec<FolderPlan> {
        let mut folders = Vec::with_capacity(24);
        match account {
            AccountId::Regular(i) => {
                let total = self.total_regular(i);
                let mut rest = total;
                for (name, kind, weight) in REGULAR_FOLDERS.iter().skip(1) {
                    let count = (f64::from(total) * weight) as u32;
                    rest -= count;
                    folders.push(FolderPlan {
                        name: Cow::Borrowed(name),
                        kind: *kind,
                        count,
                    });
                }
                folders.insert(
                    0,
                    FolderPlan {
                        name: Cow::Borrowed("INBOX"),
                        kind: FolderKind::Inbox,
                        count: rest,
                    },
                );
            }
            AccountId::Large(i) => {
                if let Some(spec) = self.preset.large.get(usize::from(i)) {
                    folders.push(FolderPlan {
                        name: Cow::Borrowed("INBOX"),
                        kind: FolderKind::Inbox,
                        count: spec.inbox,
                    });
                    let per_folder = spec
                        .tree_messages
                        .checked_div(spec.tree_folders)
                        .unwrap_or(0);
                    for f in 0..spec.tree_folders {
                        let parent = if f % 2 == 0 { "Projects" } else { "Clients" };
                        folders.push(FolderPlan {
                            name: Cow::Owned(format!("{parent}/P{:02}", f / 2 + 1)),
                            kind: FolderKind::Other,
                            count: per_folder,
                        });
                    }
                }
            }
        }
        if self.has_buckets(account) {
            folders.push(FolderPlan {
                name: Cow::Borrowed(BUCKETS_FOLDER),
                kind: FolderKind::Buckets,
                count: SizeBucket::ALL.len() as u32,
            });
        }
        folders
    }

    pub fn inbox_size(&self, account: AccountId) -> u32 {
        self.folders(account).first().map_or(0, |f| f.count)
    }

    fn key(&self, stream: u64, account: AccountId, folder: usize, idx: u32) -> u64 {
        mix_all(&[
            self.seed,
            stream,
            self.ordinal(account),
            folder as u64,
            u64::from(idx),
        ])
    }

    fn parent(&self, account: AccountId, folder: usize, idx: u32) -> Option<u32> {
        if idx == 0 {
            return None;
        }
        let mut rng = Rng::new(self.key(STREAM_THREAD, account, folder, idx));
        if !rng.chance(REPLY_RATE) {
            return None;
        }
        let distance = 1 + rng.below(MAX_PARENT_DISTANCE.min(u64::from(idx)));
        Some(idx - distance as u32)
    }

    fn write_subject(
        &self,
        corpus: &Corpus,
        account: AccountId,
        folder: usize,
        idx: u32,
        out: &mut String,
    ) {
        let mut rng = Rng::new(self.key(STREAM_SUBJECT, account, folder, idx));
        let words = 3 + rng.below(6);
        crate::corpus::phrase(&corpus.vocab, &mut rng, words, out);
    }

    pub fn write_message_id(&self, account: AccountId, folder: usize, idx: u32, out: &mut String) {
        let _ = write!(
            out,
            "s{:x}.a{}.f{folder}.m{idx}@{}",
            self.seed,
            self.ordinal(account),
            self.domain
        );
    }

    pub fn contact_sample(&self, rng: &mut Rng) -> u64 {
        self.contacts.sample(rng) as u64
    }

    pub fn write_contact(&self, corpus: &Corpus, id: u64, name: &mut String, address: &mut String) {
        corpus.person_name(id, name);
        let _ = write!(address, "contact{id:04}@{CONTACT_DOMAIN}");
    }

    pub fn write_internal_name(&self, corpus: &Corpus, account: AccountId, name: &mut String) {
        corpus.person_name(INTERNAL_NAME_BASE + self.ordinal(account), name);
    }

    pub fn message(
        &self,
        corpus: &Corpus,
        account: AccountId,
        folder_index: usize,
        folder: &FolderPlan,
        idx: u32,
        out: &mut Vec<u8>,
    ) -> MessageMeta {
        let mut subject = String::with_capacity(96);
        let mut references = String::new();
        let mut in_reply_to = String::new();
        let parent = self.parent(account, folder_index, idx);
        if let Some(parent) = parent {
            let mut chain = [0u32; MAX_REFERENCES];
            let mut chain_len = 0;
            let mut root = parent;
            let mut cursor = Some(parent);
            let mut depth = 0;
            while let Some(current) = cursor {
                if depth >= MAX_THREAD_DEPTH {
                    break;
                }
                root = current;
                if chain_len < MAX_REFERENCES {
                    chain[chain_len] = current;
                    chain_len += 1;
                }
                cursor = self.parent(account, folder_index, current);
                depth += 1;
            }
            subject.push_str("Re: ");
            self.write_subject(corpus, account, folder_index, root, &mut subject);
            for (n, id) in chain[..chain_len].iter().rev().enumerate() {
                if n > 0 {
                    references.push(' ');
                }
                references.push('<');
                self.write_message_id(account, folder_index, *id, &mut references);
                references.push('>');
            }
            self.write_message_id(account, folder_index, parent, &mut in_reply_to);
        } else {
            self.write_subject(corpus, account, folder_index, idx, &mut subject);
        }

        let mut own_address = String::with_capacity(32);
        self.write_address(account, &mut own_address);
        let mut from_name = String::with_capacity(32);
        let mut from = String::with_capacity(48);
        let mut to = String::with_capacity(48);
        let mut people = Rng::new(self.key(STREAM_PEOPLE, account, folder_index, idx));
        if folder.kind == FolderKind::Sent {
            self.write_internal_name(corpus, account, &mut from_name);
            from.push_str(&own_address);
            let mut contact_name = String::new();
            let id = self.contact_sample(&mut people);
            self.write_contact(corpus, id, &mut contact_name, &mut to);
        } else {
            to.push_str(&own_address);
            if people.chance(INTERNAL_SENDER_RATE) && self.preset.users > 1 {
                let other = AccountId::Regular(people.below(u64::from(self.preset.users)) as u32);
                self.write_internal_name(corpus, other, &mut from_name);
                self.write_address(other, &mut from);
            } else {
                let id = self.contact_sample(&mut people);
                self.write_contact(corpus, id, &mut from_name, &mut from);
            }
        }

        let mut date_rng = Rng::new(self.key(STREAM_DATE, account, folder_index, idx));
        let count = i64::from(folder.count.max(1));
        let start = DATASET_END - DATASET_SPAN;
        let offset =
            (DATASET_SPAN as f64 * (f64::from(idx) + date_rng.f64()) / count as f64) as i64;
        let date = UnixTime(start + offset.min(DATASET_SPAN));

        let mut body_rng = Rng::new(self.key(STREAM_BODY, account, folder_index, idx));
        let body = match folder.kind {
            FolderKind::Buckets => {
                BodySpec::Bucket(*SizeBucket::ALL.get(idx as usize).unwrap_or(&SizeBucket::K4))
            }
            _ => corpus_body(&mut body_rng),
        };

        let mut message_id = String::with_capacity(64);
        self.write_message_id(account, folder_index, idx, &mut message_id);
        MessageSpec {
            from_name: &from_name,
            from: &from,
            to: &to,
            subject: &subject,
            date,
            message_id: &message_id,
            in_reply_to: parent.map(|_| in_reply_to.as_str()),
            references: &references,
            extra_headers: &[],
            body,
            body_seed: body_rng.next_u64(),
        }
        .write(corpus, out);

        let mut flags = Rng::new(self.key(STREAM_FLAGS, account, folder_index, idx));
        let recent = f64::from(idx) >= f64::from(folder.count) * 0.9;
        let seen = match folder.kind {
            FolderKind::Sent | FolderKind::Trash | FolderKind::Buckets => true,
            _ if recent => flags.chance(0.5),
            _ => flags.chance(0.95),
        };
        MessageMeta {
            date,
            seen,
            flagged: flags.chance(0.02),
        }
    }
}

pub fn corpus_body(rng: &mut Rng) -> BodySpec {
    if rng.chance(ATTACHMENT_RATE) {
        let attachment = rng.log_uniform(100_000.0, 2_000_000.0) as usize;
        let text = rng.range(1_000, 6_000) as usize;
        BodySpec::TextWithAttachment {
            bytes: text,
            attachment: Attachment { bytes: attachment },
        }
    } else {
        let total = rng.log_normal(MEDIAN_MESSAGE_BYTES, MESSAGE_SIGMA) as usize;
        BodySpec::Text {
            bytes: total.saturating_sub(HEADER_ESTIMATE).clamp(200, 400_000),
        }
    }
}

fn mailbox_sizes(preset: &Preset, seed: u64) -> Vec<u32> {
    let n = preset.users as usize;
    let mut ranks: Vec<u32> = (0..preset.users).collect();
    let mut rng = Rng::from_parts(&[seed, STREAM_RANKS]);
    for i in (1..n).rev() {
        let j = rng.below_usize(i + 1);
        ranks.swap(i, j);
    }
    let size_at = |k: f64, rank: u32| -> u32 {
        (k / f64::from(rank + 1).powf(preset.zipf_exponent))
            .round()
            .clamp(
                f64::from(preset.min_messages),
                f64::from(preset.max_messages),
            ) as u32
    };
    let mean_for = |k: f64| -> f64 {
        (0..preset.users)
            .map(|r| f64::from(size_at(k, r)))
            .sum::<f64>()
            / n.max(1) as f64
    };
    let (mut lo, mut hi) = (0.0f64, f64::from(preset.max_messages) * n as f64);
    for _ in 0..60 {
        let mid = (lo + hi) / 2.0;
        if mean_for(mid) < preset.mean_messages {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    let k = hi;
    ranks.into_iter().map(|rank| size_at(k, rank)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn c_dataset_shape() {
        let ds = Dataset::new(DatasetName::C, DEFAULT_SEED, "example.org");
        let total: u64 = (0..ds.users())
            .map(|u| u64::from(ds.total_regular(u)))
            .sum();
        let mean = total as f64 / f64::from(ds.users());
        assert!((mean - 200.0).abs() < 2.0, "{mean}");
        assert_eq!(ds.accounts().count(), 1003);
        assert_eq!(ds.address(AccountId::Regular(0)), "user0001@example.org");
        assert_eq!(ds.address(AccountId::Large(2)), "large250k@example.org");
        let big = ds.folders(AccountId::Large(1));
        assert_eq!(big.len(), 22);
        assert_eq!(
            big.iter().map(|f| f.count).sum::<u32>(),
            100_000 + 50_000 + 3
        );
        let regular = ds.folders(AccountId::Regular(5));
        let sum: u32 = regular
            .iter()
            .filter(|f| f.kind != FolderKind::Buckets)
            .map(|f| f.count)
            .sum();
        assert_eq!(sum, ds.total_regular(5));
        let with_100 = (0..ds.users())
            .filter(|u| ds.inbox_size(AccountId::Regular(*u)) >= 100)
            .count();
        assert!(with_100 > 50, "{with_100}");
    }

    #[test]
    fn messages_are_deterministic_and_unique() {
        let corpus = Corpus::new(None).expect("corpus");
        let ds = Dataset::new(DatasetName::Tiny, 7, "example.org");
        let account = AccountId::Regular(3);
        let folders = ds.folders(account);
        let mut seen = std::collections::HashSet::new();
        let mut threads = 0;
        for idx in 0..folders[0].count {
            let mut a = Vec::new();
            let mut b = Vec::new();
            ds.message(&corpus, account, 0, &folders[0], idx, &mut a);
            ds.message(&corpus, account, 0, &folders[0], idx, &mut b);
            assert_eq!(a, b);
            let id_line = a
                .split(|c| *c == b'\n')
                .find(|l| l.starts_with(b"Message-ID:"))
                .expect("message id")
                .to_vec();
            assert!(seen.insert(id_line));
            if memchr::memmem::find(&a, b"In-Reply-To:").is_some() {
                threads += 1;
            }
        }
        assert!(threads > 10);
    }
}
