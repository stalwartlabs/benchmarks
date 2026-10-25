use std::fmt;
use std::time::Duration;

use serde::de::{self, Visitor};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Dur(pub Duration);

impl Dur {
    pub fn parse(text: &str) -> Option<Self> {
        let text = text.trim();
        let number = text.trim_end_matches(|c: char| c.is_ascii_alphabetic() || c.is_whitespace());
        let unit = text.strip_prefix(number)?;
        let value: f64 = number.parse().ok()?;
        let seconds = match unit.trim() {
            "us" => value / 1_000_000.0,
            "ms" => value / 1000.0,
            "" | "s" => value,
            "m" | "min" => value * 60.0,
            "h" => value * 3600.0,
            _ => return None,
        };
        (seconds.is_finite() && seconds >= 0.0).then(|| Dur(Duration::from_secs_f64(seconds)))
    }
}

impl Serialize for Dur {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let ms = self.0.as_millis();
        if ms.is_multiple_of(1000) {
            serializer.serialize_str(&format!("{}s", ms / 1000))
        } else {
            serializer.serialize_str(&format!("{ms}ms"))
        }
    }
}

struct DurVisitor;

impl Visitor<'_> for DurVisitor {
    type Value = Dur;

    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("a duration such as 60s, 500ms or 2m")
    }

    fn visit_str<E: de::Error>(self, v: &str) -> Result<Dur, E> {
        Dur::parse(v).ok_or_else(|| E::custom(format!("invalid duration {v:?}")))
    }

    fn visit_u64<E: de::Error>(self, v: u64) -> Result<Dur, E> {
        Ok(Dur(Duration::from_secs(v)))
    }

    fn visit_f64<E: de::Error>(self, v: f64) -> Result<Dur, E> {
        Dur::parse(&v.to_string()).ok_or_else(|| E::custom("invalid duration"))
    }
}

impl<'de> Deserialize<'de> for Dur {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(DurVisitor)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_units() {
        assert_eq!(Dur::parse("60s"), Some(Dur(Duration::from_secs(60))));
        assert_eq!(Dur::parse("250ms"), Some(Dur(Duration::from_millis(250))));
        assert_eq!(Dur::parse("2m"), Some(Dur(Duration::from_secs(120))));
        assert_eq!(Dur::parse("1.5s"), Some(Dur(Duration::from_millis(1500))));
        assert_eq!(Dur::parse("5x"), None);
    }
}
