use std::collections::HashSet;
use std::path::Path;

use crate::error::{Error, Result};
use crate::rng::{Rng, Zipf};

const FUNCTION_WORDS: &[&str] = &[
    "the", "of", "and", "to", "a", "in", "is", "it", "that", "for", "you", "was", "on", "are",
    "with", "as", "be", "this", "at", "have", "by", "not", "or", "from", "but", "we", "they",
    "can", "will", "all", "if", "there", "an", "so", "our", "do", "has", "more", "when", "which",
];

const ONSETS: &[&str] = &[
    "b", "c", "d", "f", "g", "h", "j", "k", "l", "m", "n", "p", "r", "s", "t", "v", "w", "z", "br",
    "cr", "dr", "fl", "gr", "pl", "pr", "st", "tr", "sh", "ch", "th", "sl", "sp",
];
const NUCLEI: &[&str] = &["a", "e", "i", "o", "u", "ai", "ea", "io", "ou", "y"];
const CODAS: &[&str] = &[
    "", "", "", "n", "r", "s", "t", "l", "m", "nd", "st", "ck", "rt",
];

const VOCAB_SEED: u64 = 0x766f_6361_6275_6c61;
pub const DEFAULT_VOCAB_SIZE: usize = 50_000;
const ZIPF_EXPONENT: f64 = 1.07;

pub struct Vocabulary {
    words: Vec<Box<str>>,
    zipf: Zipf,
}

impl Vocabulary {
    pub fn synthetic(size: usize) -> Self {
        let size = size.max(FUNCTION_WORDS.len() + 1);
        let mut words: Vec<Box<str>> = Vec::with_capacity(size);
        let mut seen: HashSet<Box<str>> = HashSet::with_capacity(size);
        for word in FUNCTION_WORDS {
            seen.insert((*word).into());
            words.push((*word).into());
        }
        let mut word = String::with_capacity(24);
        for rank in FUNCTION_WORDS.len()..size {
            let mut rng = Rng::from_parts(&[VOCAB_SEED, rank as u64]);
            let syllables = 1 + ((rank as f64).log10() * 0.6) as u64 + rng.below(2);
            word.clear();
            for _ in 0..syllables {
                push_syllable(&mut word, &mut rng);
            }
            while seen.contains(word.as_str()) {
                push_syllable(&mut word, &mut rng);
            }
            let boxed: Box<str> = word.as_str().into();
            seen.insert(boxed.clone());
            words.push(boxed);
        }
        Vocabulary::from_words(words)
    }

    pub fn from_file(path: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(path).map_err(|err| {
            Error::config(format!("cannot read word list {}: {err}", path.display()))
        })?;
        let mut seen = HashSet::new();
        let words: Vec<Box<str>> = text
            .lines()
            .filter_map(|line| line.split_whitespace().next())
            .filter(|word| word.bytes().all(|b| b.is_ascii_alphabetic()))
            .map(|word| word.to_ascii_lowercase().into_boxed_str())
            .filter(|word| seen.insert(word.clone()))
            .collect();
        if words.len() < 100 {
            return Err(Error::config(format!(
                "word list {} has fewer than 100 words",
                path.display()
            )));
        }
        Ok(Vocabulary::from_words(words))
    }

    fn from_words(words: Vec<Box<str>>) -> Self {
        let zipf = Zipf::new(words.len(), ZIPF_EXPONENT);
        Vocabulary { words, zipf }
    }

    pub fn sample(&self, rng: &mut Rng) -> &str {
        &self.words[self.zipf.sample(rng)]
    }

    pub fn by_rank(&self, rank: usize) -> &str {
        &self.words[rank.min(self.words.len() - 1)]
    }

    pub fn pick_in_ranks(&self, rng: &mut Rng, lo: usize, hi: usize) -> &str {
        let hi = hi.min(self.words.len() - 1);
        let lo = lo.min(hi);
        self.by_rank(rng.range(lo as u64, hi as u64) as usize)
    }
}

fn push_syllable(word: &mut String, rng: &mut Rng) {
    word.push_str(rng.pick(ONSETS));
    word.push_str(rng.pick(NUCLEI));
    word.push_str(rng.pick(CODAS));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn synthetic_is_unique_and_stable() {
        let a = Vocabulary::synthetic(5000);
        let b = Vocabulary::synthetic(5000);
        assert_eq!(a.words.len(), 5000);
        let unique: HashSet<&str> = a.words.iter().map(|w| w.as_ref()).collect();
        assert_eq!(unique.len(), 5000);
        assert!(a.words.iter().zip(&b.words).all(|(x, y)| x == y));
        assert_eq!(a.by_rank(0), "the");
    }

    #[test]
    fn frequent_words_are_shorter() {
        let v = Vocabulary::synthetic(50_000);
        let avg = |range: std::ops::Range<usize>| {
            let n = range.len() as f64;
            range.map(|r| v.by_rank(r).len() as f64).sum::<f64>() / n
        };
        assert!(avg(40..400) < avg(20_000..20_400));
    }
}
