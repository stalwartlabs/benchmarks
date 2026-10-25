use super::vocab::Vocabulary;
use crate::rng::Rng;

const LINE_WIDTH: usize = 72;

pub fn write_text(vocab: &Vocabulary, rng: &mut Rng, target: usize, out: &mut Vec<u8>) {
    let start = out.len();
    let mut line_len = 0usize;
    let mut sentence_left = 0u64;
    let mut paragraph_left = 3 + rng.below(5);
    while out.len() - start < target {
        if sentence_left == 0 {
            if line_len > 0 {
                out.push(b'.');
                line_len += 1;
                paragraph_left = paragraph_left.saturating_sub(1);
                if paragraph_left == 0 {
                    out.extend_from_slice(b"\r\n\r\n");
                    line_len = 0;
                    paragraph_left = 3 + rng.below(5);
                }
            }
            sentence_left = 6 + rng.below(16);
            let word = vocab.sample(rng);
            push_word(out, &mut line_len, word, Case::Capitalized);
        } else {
            let word = vocab.sample(rng);
            push_word(out, &mut line_len, word, Case::Lower);
        }
        sentence_left -= 1;
    }
    if line_len > 0 {
        out.extend_from_slice(b".\r\n");
    }
}

#[derive(Clone, Copy)]
enum Case {
    Lower,
    Capitalized,
}

fn push_word(out: &mut Vec<u8>, line_len: &mut usize, word: &str, case: Case) {
    if *line_len > 0 {
        if *line_len + 1 + word.len() > LINE_WIDTH {
            out.extend_from_slice(b"\r\n");
            *line_len = 0;
        } else {
            out.push(b' ');
            *line_len += 1;
        }
    }
    match (case, word.as_bytes().split_first()) {
        (Case::Capitalized, Some((first, rest))) => {
            out.push(first.to_ascii_uppercase());
            out.extend_from_slice(rest);
        }
        _ => out.extend_from_slice(word.as_bytes()),
    }
    *line_len += word.len();
}

pub fn phrase(vocab: &Vocabulary, rng: &mut Rng, words: u64, out: &mut String) {
    for i in 0..words {
        if i > 0 {
            out.push(' ');
        }
        let word = vocab.sample(rng);
        if i == 0 {
            let mut chars = word.chars();
            if let Some(first) = chars.next() {
                out.push(first.to_ascii_uppercase());
                out.push_str(chars.as_str());
            }
        } else {
            out.push_str(word);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_respects_target_and_line_width() {
        let vocab = Vocabulary::synthetic(10_000);
        let mut rng = Rng::new(1);
        let mut out = Vec::new();
        write_text(&vocab, &mut rng, 8192, &mut out);
        assert!(out.len() >= 8192 && out.len() < 8192 + 100);
        for line in out.split(|b| *b == b'\n') {
            assert!(line.len() <= LINE_WIDTH + 2);
            assert!(!line.starts_with(b"."));
        }
        assert!(out.ends_with(b"\r\n"));
    }
}
