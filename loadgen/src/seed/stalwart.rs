use serde_json::{Value, json};

use crate::error::{Error, Result};
use crate::net::http::HttpClient;
use crate::target::Target;

const USING: [&str; 2] = ["urn:ietf:params:jmap:core", "urn:stalwart:jmap"];
pub const MAX_BATCH: usize = 500;

pub struct StalwartApi {
    http: HttpClient,
}

#[derive(Default, Debug)]
pub struct CreateOutcome {
    pub created: u64,
    pub existed: u64,
    pub failed: u64,
    pub first_error: Option<String>,
}

impl StalwartApi {
    pub fn new(target: &Target, user: &str, password: &str) -> Self {
        let host = format!("mail.{}", target.domain);
        StalwartApi {
            http: HttpClient::new(
                target.https,
                Some(target.tls.clone()),
                &host,
                user,
                password,
            ),
        }
    }

    async fn call(&mut self, calls: Value) -> Result<Vec<Value>> {
        let body = serde_json::to_vec(&json!({"using": USING, "methodCalls": calls}))?;
        let response = self
            .http
            .request("POST", "/jmap/", "application/json", &body)
            .await?;
        if response.status != 200 {
            return Err(Error::Api(format!(
                "HTTP {}: {}",
                response.status,
                String::from_utf8_lossy(&response.body[..response.body.len().min(500)])
            )));
        }
        let mut value: Value = serde_json::from_slice(&response.body)?;
        let responses = value
            .get_mut("methodResponses")
            .and_then(Value::as_array_mut)
            .map(std::mem::take)
            .ok_or_else(|| Error::Api("missing methodResponses".into()))?;
        let mut out = Vec::with_capacity(responses.len());
        for mut response in responses {
            let name = response
                .get(0)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            let args = response.get_mut(1).map(Value::take).unwrap_or(Value::Null);
            if name == "error" {
                return Err(Error::Api(args.to_string()));
            }
            out.push(args);
        }
        Ok(out)
    }

    pub async fn domain_id(&mut self, name: &str) -> Result<String> {
        let responses = self
            .call(json!([["x:Domain/get", {"ids": null, "properties": ["id", "name"]}, "g"]]))
            .await?;
        let existing = responses
            .first()
            .and_then(|r| r.get("list"))
            .and_then(Value::as_array)
            .and_then(|list| {
                list.iter()
                    .find(|d| d.get("name").and_then(Value::as_str) == Some(name))
                    .and_then(|d| d.get("id").and_then(Value::as_str))
                    .map(str::to_string)
            });
        if let Some(id) = existing {
            return Ok(id);
        }
        let responses = self
            .call(json!([["x:Domain/set", {"create": {"d": {"name": name, "dkimManagement": {"@type": "Manual"}}}}, "s"]]))
            .await?;
        responses
            .first()
            .and_then(|r| r.pointer("/created/d/id"))
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| Error::Api(format!("cannot create domain {name}: {responses:?}")))
    }

    pub async fn create_accounts(
        &mut self,
        domain_id: &str,
        accounts: &[(String, String)],
    ) -> Result<CreateOutcome> {
        let mut create = serde_json::Map::with_capacity(accounts.len());
        for (i, (name, hash)) in accounts.iter().enumerate() {
            create.insert(
                format!("u{i}"),
                json!({
                    "@type": "User",
                    "name": name,
                    "domainId": domain_id,
                    "credentials": {"0": {"@type": "Password", "secret": hash}},
                    "roles": {"@type": "User"},
                    "permissions": {"@type": "Inherit"},
                    "encryptionAtRest": {"@type": "Disabled"}
                }),
            );
        }
        let responses = self
            .call(json!([["x:Account/set", {"create": create}, "c"]]))
            .await?;
        let response = responses
            .first()
            .ok_or_else(|| Error::Api("empty Account/set response".into()))?;
        let mut outcome = CreateOutcome {
            created: response
                .get("created")
                .and_then(Value::as_object)
                .map_or(0, |m| m.len() as u64),
            ..CreateOutcome::default()
        };
        if let Some(failed) = response.get("notCreated").and_then(Value::as_object) {
            for error in failed.values() {
                if error.get("type").and_then(Value::as_str) == Some("primaryKeyViolation") {
                    outcome.existed += 1;
                } else {
                    outcome.failed += 1;
                    outcome.first_error.get_or_insert_with(|| error.to_string());
                }
            }
        }
        Ok(outcome)
    }

    pub async fn count_accounts(&mut self) -> Result<u64> {
        let responses = self
            .call(json!([["x:Account/query", {"calculateTotal": true, "limit": 1}, "q"]]))
            .await?;
        responses
            .first()
            .and_then(|r| r.get("total"))
            .and_then(Value::as_u64)
            .ok_or_else(|| Error::Api("Account/query without total".into()))
    }
}
