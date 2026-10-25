use serde::{Deserialize, Deserializer, Serialize, Serializer};

use super::Dur;
use crate::corpus::SizeBucket;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SizeSpec {
    #[serde(rename = "4k")]
    K4,
    #[serde(rename = "64k")]
    K64,
    #[serde(rename = "1m")]
    M1,
    Mix,
}

impl SizeSpec {
    pub fn bucket(self) -> Option<SizeBucket> {
        match self {
            SizeSpec::K4 => Some(SizeBucket::K4),
            SizeSpec::K64 => Some(SizeBucket::K64),
            SizeSpec::M1 => Some(SizeBucket::M1),
            SizeSpec::Mix => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SmtpPort {
    Smtp,
    Submission,
    SubmissionStarttls,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum SmtpProbe {
    #[default]
    None,
    Imap,
    ImapPoll,
    ImapStatus,
    Sink,
}

impl SmtpProbe {
    pub fn is_imap(self) -> bool {
        matches!(
            self,
            SmtpProbe::Imap | SmtpProbe::ImapPoll | SmtpProbe::ImapStatus
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ImapRange {
    Count(u32),
    Percent(u32),
    All,
}

impl ImapRange {
    pub fn resolve(self, exists: u32) -> u32 {
        match self {
            ImapRange::Count(n) => n.min(exists),
            ImapRange::Percent(p) => (u64::from(exists) * u64::from(p) / 100).max(1) as u32,
            ImapRange::All => exists,
        }
        .min(exists)
    }

    fn parse(text: &str) -> Option<Self> {
        let text = text.trim();
        if text.eq_ignore_ascii_case("all") {
            Some(ImapRange::All)
        } else if text.eq_ignore_ascii_case("one") {
            Some(ImapRange::Count(1))
        } else if let Some(p) = text.strip_suffix('%') {
            p.trim().parse().ok().map(ImapRange::Percent)
        } else {
            text.parse().ok().map(ImapRange::Count)
        }
    }

    fn render(self) -> String {
        match self {
            ImapRange::Count(1) => "one".into(),
            ImapRange::Count(n) => n.to_string(),
            ImapRange::Percent(p) => format!("{p}%"),
            ImapRange::All => "all".into(),
        }
    }
}

impl Serialize for ImapRange {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.render())
    }
}

impl<'de> Deserialize<'de> for ImapRange {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = serde_yaml::Value::deserialize(deserializer)?;
        let text = match &value {
            serde_yaml::Value::String(s) => s.clone(),
            serde_yaml::Value::Number(n) => n.to_string(),
            _ => String::new(),
        };
        ImapRange::parse(&text)
            .ok_or_else(|| serde::de::Error::custom(format!("invalid range {value:?}")))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum FetchKind {
    FlagsAll,
    EnvelopeLast,
    BodyBucket,
    BodyRandom,
    HeaderFieldsRange,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CopyMode {
    Copy,
    Move,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SortKey {
    Date,
    From,
    Subject,
    Arrival,
}

fn inbox() -> String {
    "INBOX".into()
}

fn one() -> u32 {
    1
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct MixedProfile {
    pub sync_window: u32,
    pub fetch_new: u32,
    pub read_bodies: u32,
    pub flag_probability: f64,
    pub search_probability: f64,
    pub move_probability: f64,
    pub delete_probability: f64,
    pub search_ranks: [usize; 2],
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case", deny_unknown_fields)]
pub enum OpSpec {
    Smtp {
        port: SmtpPort,
        #[serde(default = "one")]
        recipients: u32,
        size: SizeSpec,
        #[serde(default = "one")]
        messages_per_connection: u32,
        #[serde(default)]
        relay: bool,
        #[serde(default)]
        probe: SmtpProbe,
        #[serde(default)]
        poll_gap: Dur,
    },
    ImapLogin,
    ImapList {
        #[serde(default)]
        status: bool,
    },
    ImapSelect {
        #[serde(default = "inbox")]
        folder: String,
        #[serde(default)]
        qresync_changes: u32,
    },
    ImapFetch {
        #[serde(default = "inbox")]
        folder: String,
        fetch: FetchKind,
        #[serde(default)]
        count: u32,
        #[serde(default)]
        bucket: Option<SizeSpec>,
    },
    ImapSearch {
        #[serde(default = "inbox")]
        folder: String,
        label: String,
        criteria: String,
    },
    ImapSort {
        #[serde(default = "inbox")]
        folder: String,
        #[serde(default)]
        key: Option<SortKey>,
        #[serde(default)]
        thread: bool,
    },
    ImapStore {
        #[serde(default = "inbox")]
        folder: String,
        flag: String,
        range: ImapRange,
    },
    ImapCopy {
        #[serde(default = "inbox")]
        folder: String,
        mode: CopyMode,
        range: ImapRange,
        destination: String,
    },
    ImapExpunge {
        #[serde(default = "inbox")]
        folder: String,
        range: ImapRange,
        #[serde(default)]
        uid: bool,
    },
    ImapAppend {
        folder: String,
        size: SizeSpec,
    },
    ImapMixed {
        profile: MixedProfile,
    },
}
