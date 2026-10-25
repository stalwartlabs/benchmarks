pub fn literal_len(line: &[u8]) -> Option<usize> {
    let body = line.strip_suffix(b"}")?.rsplit(|b| *b == b'{').next()?;
    let body = body.strip_suffix(b"+").unwrap_or(body);
    if body.is_empty() || !body.iter().all(u8::is_ascii_digit) {
        return None;
    }
    std::str::from_utf8(body).ok()?.parse().ok()
}

pub fn trim_crlf(line: &[u8]) -> &[u8] {
    let line = line.strip_suffix(b"\n").unwrap_or(line);
    line.strip_suffix(b"\r").unwrap_or(line)
}

pub fn parse_u64(token: &[u8]) -> Option<u64> {
    if token.is_empty() || token.len() > 19 || !token.iter().all(u8::is_ascii_digit) {
        return None;
    }
    Some(
        token
            .iter()
            .fold(0u64, |acc, d| acc * 10 + u64::from(d - b'0')),
    )
}

pub fn tokens(text: &[u8]) -> impl Iterator<Item = &[u8]> {
    text.split(|b| *b == b' ').filter(|t| !t.is_empty())
}

pub fn count_numbers(text: &[u8]) -> u32 {
    let mut count = 0;
    let mut in_number = false;
    for b in text {
        let digit = b.is_ascii_digit();
        if digit && !in_number {
            count += 1;
        }
        in_number = digit;
    }
    count
}

fn resp_code(text: &[u8]) -> Option<&[u8]> {
    let mut parts = text.splitn(2, |b| *b == b'[');
    parts.next()?;
    parts.next()?.split(|b| *b == b']').next()
}

pub fn resp_code_value(text: &[u8], code: &[u8]) -> Option<u64> {
    let mut parts = tokens(resp_code(text)?);
    if !parts.next()?.eq_ignore_ascii_case(code) {
        return None;
    }
    parse_u64(parts.next()?)
}

pub fn resp_code_second(text: &[u8], code: &[u8]) -> Option<u64> {
    let mut parts = tokens(resp_code(text)?);
    if !parts.next()?.eq_ignore_ascii_case(code) {
        return None;
    }
    parts.next()?;
    parse_u64(parts.next()?)
}

#[derive(Debug)]
pub struct ListEntry {
    pub delimiter: u8,
    pub name: String,
    pub selectable: bool,
}

pub fn list_name(text: &[u8]) -> Option<ListEntry> {
    let mut parts = text.splitn(2, |b| *b == b')');
    let flags = parts.next()?;
    let selectable = !tokens(flags).any(|flag| {
        let flag = flag.strip_prefix(b"(").unwrap_or(flag);
        flag.eq_ignore_ascii_case(b"\\Noselect") || flag.eq_ignore_ascii_case(b"\\NonExistent")
    });
    let rest = parts.next()?.trim_ascii_start();
    let (delimiter, rest) = if let Some(rest) = rest.strip_prefix(b"NIL") {
        (0, rest)
    } else {
        let [b'"', d, b'"', rest @ ..] = rest else {
            return None;
        };
        (*d, rest)
    };
    let name = rest.trim_ascii();
    let name = name
        .strip_prefix(b"\"")
        .and_then(|n| n.strip_suffix(b"\""))
        .unwrap_or(name);
    Some(ListEntry {
        delimiter,
        name: String::from_utf8_lossy(name)
            .replace("\\\"", "\"")
            .replace("\\\\", "\\"),
        selectable,
    })
}

pub fn status_messages(text: &[u8]) -> Option<u32> {
    let inner = text.rsplit(|b| *b == b'(').next()?;
    let inner = inner.split(|b| *b == b')').next()?;
    let mut parts = tokens(inner);
    while let Some(name) = parts.next() {
        let value = parts.next()?;
        if name.eq_ignore_ascii_case(b"MESSAGES") {
            return parse_u64(value).and_then(|v| u32::try_from(v).ok());
        }
    }
    None
}

pub fn has_resp_code(text: &[u8], code: &[u8]) -> bool {
    resp_code(text)
        .and_then(|inner| tokens(inner).next())
        .is_some_and(|name| name.eq_ignore_ascii_case(code))
}

pub fn quote(out: &mut Vec<u8>, value: &str) {
    out.push(b'"');
    for b in value.bytes() {
        if b == b'"' || b == b'\\' {
            out.push(b'\\');
        }
        out.push(b);
    }
    out.push(b'"');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn literals() {
        assert_eq!(literal_len(b"* 1 FETCH (BODY[] {1234}"), Some(1234));
        assert_eq!(literal_len(b"A1 APPEND x {12+}"), Some(12));
        assert_eq!(literal_len(b"* OK done"), None);
        assert_eq!(literal_len(b"* OK {}"), None);
    }

    #[test]
    fn counting() {
        assert_eq!(count_numbers(b"1 2 3 40 500"), 5);
        assert_eq!(count_numbers(b"(1)(2 3)(4 (5)(6))"), 6);
        assert_eq!(count_numbers(b""), 0);
    }

    #[test]
    fn codes() {
        assert_eq!(
            resp_code_value(b"OK [UIDVALIDITY 3857529045] UIDs valid", b"UIDVALIDITY"),
            Some(3_857_529_045)
        );
        assert_eq!(
            resp_code_value(b"OK [HIGHESTMODSEQ 715194045007]", b"HIGHESTMODSEQ"),
            Some(715_194_045_007)
        );
        assert_eq!(
            resp_code_second(b"OK [APPENDUID 38505 3955] done", b"APPENDUID"),
            Some(3955)
        );
        assert_eq!(resp_code_value(b"OK done", b"UIDNEXT"), None);
        assert!(has_resp_code(
            b"NO [ALREADYEXISTS] exists",
            b"ALREADYEXISTS"
        ));
    }

    #[test]
    fn list_and_status() {
        let entry = list_name(br#"(\HasNoChildren) "/" "Lists/Dev""#).expect("entry");
        assert_eq!(
            (entry.delimiter, entry.name.as_str(), entry.selectable),
            (b'/', "Lists/Dev", true)
        );
        let entry = list_name(br#"(\Noselect \HasChildren) "." "Lists""#).expect("entry");
        assert_eq!(
            (entry.delimiter, entry.name.as_str(), entry.selectable),
            (b'.', "Lists", false)
        );
        let entry = list_name(br#"(\HasNoChildren) "/" INBOX"#).expect("entry");
        assert_eq!(entry.name, "INBOX");
        assert_eq!(
            status_messages(br#""Lists/Dev" (MESSAGES 231 UIDNEXT 44292)"#),
            Some(231)
        );
    }
}
