mod date;
mod message;
mod text;
mod vocab;

use std::path::Path;

pub use date::UnixTime;
pub use message::{Attachment, BodySpec, MessageSpec, SizeBucket};
pub use text::phrase;
pub use vocab::{DEFAULT_VOCAB_SIZE, Vocabulary};

use crate::error::Result;
use crate::rng::Rng;

const NAME_RANK_START: usize = 3000;
const NAME_RANK_SPAN: usize = 2000;

pub struct Corpus {
    pub vocab: Vocabulary,
}

impl Corpus {
    pub fn new(word_list: Option<&Path>) -> Result<Self> {
        let vocab = match word_list {
            Some(path) => Vocabulary::from_file(path)?,
            None => Vocabulary::synthetic(DEFAULT_VOCAB_SIZE),
        };
        Ok(Corpus { vocab })
    }

    pub fn person_name(&self, id: u64, out: &mut String) {
        let mut rng = Rng::from_parts(&[0x6e61_6d65, id]);
        for i in 0..2 {
            if i > 0 {
                out.push(' ');
            }
            let word = self.vocab.pick_in_ranks(
                &mut rng,
                NAME_RANK_START,
                NAME_RANK_START + NAME_RANK_SPAN,
            );
            let mut chars = word.chars();
            if let Some(first) = chars.next() {
                out.push(first.to_ascii_uppercase());
                out.push_str(chars.as_str());
            }
        }
    }

    pub fn surname(&self, id: u64) -> String {
        let mut name = String::new();
        self.person_name(id, &mut name);
        name.rsplit(' ').next().unwrap_or_default().to_string()
    }
}
