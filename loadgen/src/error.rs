use std::fmt;
use std::io;
use std::time::Duration;

#[derive(Debug)]
pub enum Error {
    Io(io::Error),
    Tls(rustls::Error),
    Timeout(Duration),
    Protocol(String),
    Rejected {
        command: &'static str,
        reply: String,
    },
    Config(String),
    Json(serde_json::Error),
    Yaml(serde_yaml::Error),
    Api(String),
    Mismatch(String),
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn kind(&self) -> &'static str {
        match self {
            Error::Io(_) => "io",
            Error::Tls(_) => "tls",
            Error::Timeout(_) => "timeout",
            Error::Protocol(_) => "protocol",
            Error::Rejected { .. } => "rejected",
            Error::Config(_) => "config",
            Error::Json(_) | Error::Yaml(_) => "parse",
            Error::Api(_) => "api",
            Error::Mismatch(_) => "mismatch",
        }
    }

    #[cold]
    pub fn protocol(context: &str, line: &[u8]) -> Self {
        Error::Protocol(format!(
            "{context}: {}",
            String::from_utf8_lossy(&line[..line.len().min(200)]).trim_end()
        ))
    }

    #[cold]
    pub fn rejected(command: &'static str, line: &[u8]) -> Self {
        Error::Rejected {
            command,
            reply: String::from_utf8_lossy(&line[..line.len().min(200)])
                .trim_end()
                .to_string(),
        }
    }

    pub fn config(message: impl Into<String>) -> Self {
        Error::Config(message.into())
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Io(err) => write!(f, "I/O error: {err}"),
            Error::Tls(err) => write!(f, "TLS error: {err}"),
            Error::Timeout(after) => write!(f, "timed out after {after:?}"),
            Error::Protocol(message) => write!(f, "protocol error: {message}"),
            Error::Rejected { command, reply } => write!(f, "{command} rejected: {reply}"),
            Error::Config(message) => write!(f, "configuration error: {message}"),
            Error::Json(err) => write!(f, "JSON error: {err}"),
            Error::Yaml(err) => write!(f, "YAML error: {err}"),
            Error::Api(message) => write!(f, "API error: {message}"),
            Error::Mismatch(message) => write!(f, "verification mismatch: {message}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<io::Error> for Error {
    fn from(err: io::Error) -> Self {
        Error::Io(err)
    }
}

impl From<rustls::Error> for Error {
    fn from(err: rustls::Error) -> Self {
        Error::Tls(err)
    }
}

impl From<serde_json::Error> for Error {
    fn from(err: serde_json::Error) -> Self {
        Error::Json(err)
    }
}

impl From<serde_yaml::Error> for Error {
    fn from(err: serde_yaml::Error) -> Self {
        Error::Yaml(err)
    }
}
