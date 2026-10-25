use std::collections::HashSet;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_yaml::{Mapping, Value};

use super::profile::Profile;
use super::{CacheState, Cell, LoadHosts, Mode, Variant};
use crate::dataset::DatasetName;
use crate::error::{Error, Result};

pub struct ScenarioFile {
    pub path: PathBuf,
    pub cells: Vec<Cell>,
}

#[derive(Serialize)]
pub struct CellListing<'a> {
    pub id: &'a str,
    pub scenario: &'a str,
    pub file: String,
    pub title: &'a str,
    pub family: &'a str,
    pub mode: Mode,
    pub targets: &'a [String],
    pub variants: &'a [Variant],
    pub cache: CacheState,
    pub load_hosts: LoadHosts,
    pub repetitions: u32,
    pub dataset: DatasetName,
    pub group: Option<&'a str>,
}

impl ScenarioFile {
    pub fn load(path: &Path, profile: Option<&Profile>) -> Result<Self> {
        let text = std::fs::read_to_string(path)
            .map_err(|err| Error::config(format!("cannot read {}: {err}", path.display())))?;
        let cells = expand(&text, profile)
            .map_err(|err| Error::config(format!("{}: {err}", path.display())))?;
        Ok(ScenarioFile {
            path: path.to_path_buf(),
            cells,
        })
    }

    pub fn cell(&self, id: &str) -> Result<&Cell> {
        self.cells
            .iter()
            .find(|c| c.id == id)
            .ok_or_else(|| Error::config(format!("cell {id} not found in {}", self.path.display())))
    }

    pub fn listing(&self) -> impl Iterator<Item = CellListing<'_>> {
        self.cells.iter().map(|cell| CellListing {
            id: &cell.id,
            scenario: &cell.scenario,
            file: repo_relative(&self.path),
            title: &cell.title,
            family: &cell.family,
            mode: cell.mode,
            targets: &cell.targets,
            variants: &cell.variants,
            cache: cell.cache,
            load_hosts: cell.load_hosts,
            repetitions: cell.repetitions,
            dataset: cell.dataset,
            group: cell.group.as_deref(),
        })
    }
}

fn repo_relative(path: &Path) -> String {
    let components: Vec<_> = path.components().collect();
    match components
        .iter()
        .rposition(|c| c.as_os_str() == "scenarios")
    {
        Some(start) => components
            .get(start..)
            .unwrap_or_default()
            .iter()
            .collect::<PathBuf>()
            .display()
            .to_string(),
        None => path.display().to_string(),
    }
}

fn expand(text: &str, profile: Option<&Profile>) -> Result<Vec<Cell>> {
    let mut base: Mapping = serde_yaml::from_str(text)?;
    let id = base
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::config("missing id"))?
        .to_string();
    base.insert("scenario".into(), Value::String(id.clone()));
    let matrix = match base.remove("matrix") {
        Some(Value::Mapping(m)) => m,
        Some(_) => return Err(Error::config("matrix must be a mapping")),
        None => Mapping::new(),
    };
    let axes: Vec<(String, Vec<Value>)> = matrix
        .into_iter()
        .map(|(k, v)| {
            let key = k
                .as_str()
                .ok_or_else(|| Error::config("matrix keys must be strings"))?
                .to_string();
            match v {
                Value::Sequence(values) if !values.is_empty() => Ok((key, values)),
                _ => Err(Error::config(format!(
                    "matrix {key} must be a non-empty list"
                ))),
            }
        })
        .collect::<Result<_>>()?;

    let total: usize = axes.iter().map(|(_, v)| v.len()).product();
    let mut cells = Vec::with_capacity(total);
    let mut counters = vec![0usize; axes.len()];
    for _ in 0..total {
        let mut cell = Value::Mapping(base.clone());
        let mut cell_id = id.clone();
        for ((path, values), index) in axes.iter().zip(&counters) {
            let value = &values[*index];
            set_path(&mut cell, path, value.clone())?;
            cell_id.push('-');
            push_suffix(&mut cell_id, path, value);
        }
        let keep = match profile {
            Some(profile) => profile.apply(&cell_id, &mut cell)?,
            None => true,
        };
        if let Value::Mapping(m) = &mut cell {
            m.insert("id".into(), Value::String(cell_id));
        }
        if keep {
            cells.push(serde_yaml::from_value::<Cell>(cell)?);
        }
        for (counter, (_, values)) in counters.iter_mut().zip(&axes).rev() {
            *counter += 1;
            if *counter < values.len() {
                break;
            }
            *counter = 0;
        }
    }
    Ok(cells)
}

pub(super) fn set_path(root: &mut Value, path: &str, value: Value) -> Result<()> {
    let mut node = root;
    let mut parts = path.split('.').peekable();
    while let Some(part) = parts.next() {
        let Value::Mapping(map) = node else {
            return Err(Error::config(format!(
                "matrix path {path} crosses a non-mapping"
            )));
        };
        if parts.peek().is_none() {
            map.insert(part.into(), value);
            return Ok(());
        }
        node = map
            .entry(part.into())
            .or_insert_with(|| Value::Mapping(Mapping::new()));
    }
    Ok(())
}

fn push_suffix(out: &mut String, path: &str, value: &Value) {
    let segment = path.rsplit('.').next().unwrap_or(path);
    let text = match value {
        Value::Number(n) => format!("{segment}{n}"),
        Value::Bool(b) => format!("{segment}-{b}"),
        Value::String(s) => s.clone(),
        other => serde_yaml::to_string(other).unwrap_or_default(),
    };
    out.extend(text.chars().map(|c| {
        if c.is_ascii_alphanumeric() {
            c.to_ascii_lowercase()
        } else if c == '%' {
            'p'
        } else {
            '_'
        }
    }));
}

pub fn list_dir(dir: &Path, profile: Option<&Profile>) -> Result<Vec<ScenarioFile>> {
    let mut paths = Vec::new();
    collect_yaml(dir, &mut paths)?;
    paths.sort_unstable();
    let mut files = Vec::with_capacity(paths.len());
    let mut ids = HashSet::new();
    for path in paths {
        let file = ScenarioFile::load(&path, profile)?;
        for cell in &file.cells {
            if !ids.insert(cell.id.clone()) {
                return Err(Error::config(format!(
                    "duplicate cell id {} in {}",
                    cell.id,
                    path.display()
                )));
            }
        }
        files.push(file);
    }
    Ok(files)
}

fn collect_yaml(dir: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    if dir.is_file() {
        out.push(dir.to_path_buf());
        return Ok(());
    }
    let entries = std::fs::read_dir(dir)
        .map_err(|err| Error::config(format!("cannot read {}: {err}", dir.display())))?;
    for entry in entries {
        let path = entry?.path();
        if path.is_dir() {
            collect_yaml(&path, out)?;
        } else if path
            .extension()
            .is_some_and(|ext| ext == "yaml" || ext == "yml")
        {
            out.push(path);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
id: c01
title: SMTP inbound
family: smtp-in
mode: latency
targets: [stalwart, dovecot]
variants: [{target: dovecot, name: fsync-always}]
cache: warm
load_hosts: 1
dataset: c
load: {model: closed, sessions: 1, samples: 10000, max_duration: 15m}
users: {set: regular}
op: {kind: smtp, port: smtp, size: 4k}
matrix:
  load.sessions: [1, 16]
  op.size: [4k, 64k, 1m, mix]
"#;

    #[test]
    fn matrix_expands() {
        let cells = expand(SAMPLE, None).expect("expand");
        assert_eq!(cells.len(), 8);
        assert_eq!(cells[0].id, "c01-sessions1-4k");
        assert_eq!(cells[7].id, "c01-sessions16-mix");
        assert!(cells.iter().all(|c| c.scenario == "c01"));
    }

    #[test]
    fn load_hosts_all() {
        let text = SAMPLE.replace("load_hosts: 1", "load_hosts: all");
        let cells = expand(&text, None).expect("expand");
        assert_eq!(
            cells[0].load_hosts,
            LoadHosts::All(super::super::AllHosts::All)
        );
    }
}
