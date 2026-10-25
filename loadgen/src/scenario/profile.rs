use std::path::Path;

use serde::Deserialize;
use serde_yaml::{Mapping, Value};

use super::file::set_path;
use crate::error::{Error, Result};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Rule {
    #[serde(rename = "match")]
    patterns: Vec<String>,
    #[serde(default)]
    exclude: Option<bool>,
    #[serde(default)]
    set: Mapping,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Group {
    name: String,
    #[serde(rename = "match")]
    patterns: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Profile {
    pub id: String,
    #[serde(default)]
    rules: Vec<Rule>,
    #[serde(default)]
    groups: Vec<Group>,
}

impl Profile {
    pub fn load(path: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(path).map_err(|err| {
            Error::config(format!("cannot read profile {}: {err}", path.display()))
        })?;
        serde_yaml::from_str(&text)
            .map_err(|err| Error::config(format!("{}: {err}", path.display())))
    }

    pub fn apply(&self, cell_id: &str, cell: &mut Value) -> Result<bool> {
        let mut keep = true;
        for rule in self
            .rules
            .iter()
            .filter(|r| matches_any(&r.patterns, cell_id))
        {
            if let Some(exclude) = rule.exclude {
                keep = !exclude;
            }
            for (path, value) in &rule.set {
                let path = path
                    .as_str()
                    .ok_or_else(|| Error::config("profile set keys must be strings"))?;
                set_path(cell, path, value.clone())?;
            }
        }
        if let (Some(group), Value::Mapping(map)) = (
            self.groups
                .iter()
                .find(|g| matches_any(&g.patterns, cell_id)),
            &mut *cell,
        ) {
            map.insert("group".into(), Value::String(group.name.clone()));
        }
        Ok(keep)
    }
}

fn matches_any(patterns: &[String], text: &str) -> bool {
    patterns.iter().any(|p| glob(p, text))
}

pub fn glob(pattern: &str, text: &str) -> bool {
    let mut parts = pattern.split('*');
    let Some(first) = parts.next() else {
        return text.is_empty();
    };
    let Some(mut rest) = text.strip_prefix(first) else {
        return false;
    };
    let parts: Vec<&str> = parts.collect();
    let Some((last, middle)) = parts.split_last() else {
        return rest.is_empty();
    };
    for part in middle {
        match rest.find(part) {
            Some(pos) => rest = rest.get(pos + part.len()..).unwrap_or_default(),
            None => return false,
        }
    }
    rest.ends_with(last)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn globbing() {
        assert!(glob("c02-idle-*", "c02-idle-sessions1-recipients1-4k"));
        assert!(!glob("c02-idle-*", "c02-sessions1"));
        assert!(glob("l*-cold-*", "l12-sort-cold-large10k-date"));
        assert!(glob("*-10p*", "l14-copy-move-large250k-move-10p"));
        assert!(glob("c07-sessions1", "c07-sessions1"));
        assert!(!glob("c07-sessions1", "c07-sessions16"));
        assert!(glob("*", "anything"));
    }

    #[test]
    fn rules_apply_in_order() {
        let profile: Profile = serde_yaml::from_str(
            r#"
id: test
rules:
  - match: ["c02-idle-*"]
    exclude: true
  - match: ["c02-idle-sessions1-recipients1-4k"]
    exclude: false
    set: {repetitions: 1, load.samples: 500, variants: []}
groups:
  - {name: A, match: ["c0*"]}
"#,
        )
        .expect("profile");
        let mut cell: Value =
            serde_yaml::from_str("{repetitions: 3, load: {samples: 10000}}").expect("yaml");
        assert!(
            !profile
                .apply("c02-idle-sessions16-recipients1-4k", &mut cell.clone())
                .expect("apply")
        );
        assert!(
            profile
                .apply("c02-idle-sessions1-recipients1-4k", &mut cell)
                .expect("apply")
        );
        assert_eq!(cell["repetitions"], Value::from(1));
        assert_eq!(cell["load"]["samples"], Value::from(500));
        assert_eq!(cell["group"], Value::from("A"));
    }
}
