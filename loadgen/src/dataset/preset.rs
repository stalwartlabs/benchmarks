use serde::{Deserialize, Serialize};

pub struct LargeSpec {
    pub name: &'static str,
    pub inbox: u32,
    pub tree_folders: u32,
    pub tree_messages: u32,
}

pub struct Preset {
    pub users: u32,
    pub mean_messages: f64,
    pub zipf_exponent: f64,
    pub min_messages: u32,
    pub max_messages: u32,
    pub large: &'static [LargeSpec],
    pub bucket_users: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, clap::ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum DatasetName {
    Tiny,
    C,
    S,
    M,
    L,
}

const LARGE_C: &[LargeSpec] = &[
    LargeSpec {
        name: "large10k",
        inbox: 10_000,
        tree_folders: 0,
        tree_messages: 0,
    },
    LargeSpec {
        name: "large100k",
        inbox: 100_000,
        tree_folders: 20,
        tree_messages: 50_000,
    },
    LargeSpec {
        name: "large250k",
        inbox: 250_000,
        tree_folders: 0,
        tree_messages: 0,
    },
];

const LARGE_TINY: &[LargeSpec] = &[
    LargeSpec {
        name: "large10k",
        inbox: 100,
        tree_folders: 0,
        tree_messages: 0,
    },
    LargeSpec {
        name: "large100k",
        inbox: 1_000,
        tree_folders: 20,
        tree_messages: 500,
    },
    LargeSpec {
        name: "large250k",
        inbox: 2_500,
        tree_folders: 0,
        tree_messages: 0,
    },
];

impl DatasetName {
    pub fn preset(self) -> Preset {
        match self {
            DatasetName::Tiny => Preset {
                users: 200,
                mean_messages: 220.0,
                zipf_exponent: 1.0,
                min_messages: 190,
                max_messages: 1_000,
                large: LARGE_TINY,
                bucket_users: 20,
            },
            DatasetName::C => Preset {
                users: 1_000,
                mean_messages: 200.0,
                zipf_exponent: 1.0,
                min_messages: 5,
                max_messages: 20_000,
                large: LARGE_C,
                bucket_users: 100,
            },
            DatasetName::S => Preset {
                users: 1_000,
                mean_messages: 200.0,
                zipf_exponent: 1.0,
                min_messages: 5,
                max_messages: 20_000,
                large: &[],
                bucket_users: 100,
            },
            DatasetName::M => Preset {
                users: 300_000,
                mean_messages: 50.0,
                zipf_exponent: 0.85,
                min_messages: 2,
                max_messages: 10_000,
                large: &[],
                bucket_users: 1_000,
            },
            DatasetName::L => Preset {
                users: 1_000_000,
                mean_messages: 50.0,
                zipf_exponent: 0.85,
                min_messages: 2,
                max_messages: 10_000,
                large: &[],
                bucket_users: 1_000,
            },
        }
    }
}
