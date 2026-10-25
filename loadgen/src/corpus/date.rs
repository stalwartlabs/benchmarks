use std::fmt::Write;

const MONTHS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];
const WEEKDAYS: [&str; 7] = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"];

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct UnixTime(pub i64);

struct Civil {
    year: i64,
    month: usize,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
    weekday: usize,
}

impl UnixTime {
    fn civil(self) -> Civil {
        let days = self.0.div_euclid(86_400);
        let secs = self.0.rem_euclid(86_400);
        let z = days + 719_468;
        let era = z.div_euclid(146_097);
        let doe = z - era * 146_097;
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let day = doy - (153 * mp + 2) / 5 + 1;
        let month = if mp < 10 { mp + 3 } else { mp - 9 };
        let year = yoe + era * 400 + i64::from(month <= 2);
        Civil {
            year,
            month: (month - 1) as usize,
            day,
            hour: secs / 3600,
            minute: secs % 3600 / 60,
            second: secs % 60,
            weekday: days.rem_euclid(7) as usize,
        }
    }

    pub fn write_rfc5322(self, out: &mut String) {
        let c = self.civil();
        let _ = write!(
            out,
            "{}, {} {} {} {:02}:{:02}:{:02} +0000",
            WEEKDAYS[c.weekday], c.day, MONTHS[c.month], c.year, c.hour, c.minute, c.second
        );
    }

    pub fn write_imap(self, out: &mut String) {
        let c = self.civil();
        let _ = write!(
            out,
            "\"{:02}-{}-{} {:02}:{:02}:{:02} +0000\"",
            c.day, MONTHS[c.month], c.year, c.hour, c.minute, c.second
        );
    }

    pub fn write_imap_date(self, out: &mut String) {
        let c = self.civil();
        let _ = write!(out, "{}-{}-{}", c.day, MONTHS[c.month], c.year);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats() {
        let mut s = String::new();
        UnixTime(1_761_350_400).write_rfc5322(&mut s);
        assert_eq!(s, "Sat, 25 Oct 2025 00:00:00 +0000");
        s.clear();
        UnixTime(951_782_400 + 3661).write_imap(&mut s);
        assert_eq!(s, "\"29-Feb-2000 01:01:01 +0000\"");
        s.clear();
        UnixTime(0).write_imap_date(&mut s);
        assert_eq!(s, "1-Jan-1970");
    }
}
