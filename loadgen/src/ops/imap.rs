use std::fmt::Write;

use super::{Ctx, Emitter, Session, WorkerState};
use crate::corpus::UnixTime;
use crate::error::{Error, Result};
use crate::proto::imap::{ImapClient, Summary, quote};
use crate::scenario::{CopyMode, FetchKind, ImapRange, LoadSpec, OpSpec, SizeSpec, SortKey};
use crate::stats::{Phase, Timer};

const DATASET_END: i64 = 1_761_955_200;
const DAY: i64 = 86_400;
const EXPUNGE_BATCH: usize = 100;
const COLD_SELECT: &str = "imap.select_cold";
const COLD_OP: &str = "imap.cold_op";

fn session_ops(ctx: &Ctx) -> u32 {
    match &ctx.cell.load {
        LoadSpec::Closed(spec) => spec.session_ops.max(1),
        LoadSpec::Open(_) => 1,
    }
}

fn op_folders(op: &OpSpec) -> Option<&str> {
    match op {
        OpSpec::ImapCopy { destination, .. } => Some(destination),
        OpSpec::ImapAppend { folder, .. } => Some(folder),
        _ => None,
    }
}

pub async fn open_session(ctx: &Ctx, ws: &mut WorkerState) -> Result<Session> {
    let account = ws.pick_user();
    let mut timer = Timer::start();
    let mut client = ImapClient::connect_login(
        ctx.target.imap,
        &ctx.target.tls,
        &ctx.dataset.address(account),
        &ctx.dataset.password(account),
        &mut timer,
    )
    .await?;
    client.setup().await?;
    if let Some(folder) = op_folders(&ctx.cell.op) {
        create_folder(&mut client, folder).await?;
    }
    Ok(Session {
        client,
        selected: None,
        exists: 0,
        ops_left: session_ops(ctx),
    })
}

pub async fn create_folder(client: &mut ImapClient, folder: &str) -> Result<()> {
    if folder.eq_ignore_ascii_case("INBOX") {
        return Ok(());
    }
    let mut cmd = Vec::with_capacity(folder.len() + 16);
    cmd.extend_from_slice(b"CREATE ");
    quote(&mut cmd, &client.folder_name(folder));
    match client
        .run_raw(&cmd, "CREATE", crate::proto::imap::Capture::None)
        .await
    {
        Ok(_) | Err(Error::Rejected { .. }) => Ok(()),
        Err(err) => Err(err),
    }
}

pub async fn select(client: &mut ImapClient, folder: &str) -> Result<Summary> {
    let mut cmd = Vec::with_capacity(folder.len() + 16);
    cmd.extend_from_slice(b"SELECT ");
    quote(&mut cmd, &client.folder_name(folder));
    client
        .run_raw(&cmd, "SELECT", crate::proto::imap::Capture::None)
        .await
}

pub async fn end_session(ctx: &Ctx, mut session: Session) {
    if let OpSpec::ImapAppend { folder, .. } = &ctx.cell.op {
        let mut cmd = Vec::with_capacity(folder.len() + 16);
        if session.selected.is_some() {
            let _ = session.client.run("UNSELECT", "UNSELECT").await;
        }
        cmd.extend_from_slice(b"DELETE ");
        quote(&mut cmd, &session.client.folder_name(folder));
        let _ = session
            .client
            .run_raw(&cmd, "DELETE", crate::proto::imap::Capture::None)
            .await;
    }
    let _ = session.client.logout().await;
}

async fn session_for(
    ctx: &Ctx,
    ws: &mut WorkerState,
    folder: &str,
    em: Emitter<'_>,
) -> Result<bool> {
    if ws.session.as_ref().is_some_and(|s| s.ops_left == 0)
        && let Some(old) = ws.session.take()
    {
        end_session(ctx, old).await;
    }
    let opened = ws.session.is_none();
    if opened {
        let session = open_session(ctx, ws).await?;
        ws.session = Some(session);
    }
    let cold = opened && ctx.cell.cold_open;
    let session = ws
        .session
        .as_mut()
        .ok_or_else(|| Error::Protocol("no session".into()))?;
    if session.selected.as_deref() != Some(folder) {
        let timer = Timer::start();
        let summary = select(&mut session.client, folder).await?;
        if cold {
            em.sample(COLD_SELECT, &timer, summary.exists.map(u64::from));
        }
        session.exists = summary.exists.unwrap_or(0);
        session.selected = Some(folder.to_string());
    }
    session.ops_left -= 1;
    Ok(cold)
}

pub async fn login(
    ctx: &Ctx,
    ws: &mut WorkerState,
    em: Emitter<'_>,
    mut timer: Timer,
) -> Result<()> {
    let account = ws.pick_user();
    let client = ImapClient::connect_login(
        ctx.target.imap,
        &ctx.target.tls,
        &ctx.dataset.address(account),
        &ctx.dataset.password(account),
        &mut timer,
    )
    .await?;
    client.logout().await?;
    timer.mark(Phase::Command);
    em.sample("imap.login", &timer, None);
    Ok(())
}

fn seq_range(start: u32, count: u32) -> String {
    if count <= 1 {
        start.to_string()
    } else {
        format!("{start}:{}", start + count - 1)
    }
}

fn expand_criteria(ctx: &Ctx, ws: &mut WorkerState, template: &str) -> String {
    let mut out = String::with_capacity(template.len() + 32);
    let mut rest = template;
    while let Some((before, after)) = rest.split_once('{') {
        out.push_str(before);
        let Some((token, tail)) = after.split_once('}') else {
            out.push('{');
            rest = after;
            continue;
        };
        rest = tail;
        let (name, arg) = token.split_once(':').unwrap_or((token, ""));
        match name {
            "word" => {
                let (lo, hi) = arg.split_once('-').unwrap_or((arg, arg));
                let lo = lo.parse().unwrap_or(0);
                let hi = hi.parse().unwrap_or(lo);
                out.push_str(ctx.corpus.vocab.pick_in_ranks(&mut ws.rng, lo, hi));
            }
            "contact" => {
                let id = ctx.dataset.contact_sample(&mut ws.rng);
                out.push_str(&ctx.corpus.surname(id));
            }
            "since" => {
                let days: i64 = arg.parse().unwrap_or(30);
                UnixTime(DATASET_END - days * DAY).write_imap_date(&mut out);
            }
            _ => {
                out.push('{');
                out.push_str(token);
                out.push('}');
            }
        }
    }
    out.push_str(rest);
    out
}

pub async fn execute(ctx: &Ctx, ws: &mut WorkerState, em: Emitter<'_>) -> Result<()> {
    let op = &ctx.cell.op;
    let folder = match op {
        OpSpec::ImapSelect { folder, .. }
        | OpSpec::ImapSearch { folder, .. }
        | OpSpec::ImapSort { folder, .. }
        | OpSpec::ImapStore { folder, .. }
        | OpSpec::ImapCopy { folder, .. }
        | OpSpec::ImapExpunge { folder, .. } => folder.as_str(),
        OpSpec::ImapFetch {
            fetch: FetchKind::BodyBucket,
            ..
        } => crate::dataset::BUCKETS_FOLDER,
        OpSpec::ImapFetch { folder, .. } => folder.as_str(),
        _ => "INBOX",
    };
    let toggle = ws.toggle;
    ws.toggle = !toggle;
    let start_seed = ws.rng.next_u64();
    let label = ctx.primary_label();
    let search = match op {
        OpSpec::ImapSearch { criteria, .. } => Some(expand_criteria(ctx, ws, criteria)),
        _ => None,
    };
    if let OpSpec::ImapAppend { .. } = op {
        let templates = ctx
            .templates
            .as_ref()
            .ok_or_else(|| Error::config("missing templates"))?;
        let id = ctx.next_id();
        let message_id = format!("a{:x}.{id}@loadgen.{}", ctx.nonce, ctx.target.domain);
        templates.write(
            &mut ws.rng,
            &super::Headers {
                from_name: "Load Generator",
                from: "loadgen@example.com",
                to: "user@example.org",
                subject: "Appended message",
                message_id: &message_id,
                date: UnixTime(DATASET_END),
                probe: None,
            },
            &mut ws.buf,
        );
    }
    let em = if session_for(ctx, ws, folder, em).await? {
        em.with_alias(COLD_OP)
    } else {
        em
    };
    let WorkerState { session, buf, .. } = ws;
    let session = session
        .as_mut()
        .ok_or_else(|| Error::Protocol("no session".into()))?;
    let exists = session.exists;
    let client = &mut session.client;
    let mut rng = crate::rng::Rng::new(start_seed);
    let pick_start = |rng: &mut crate::rng::Rng, count: u32| -> u32 {
        1 + rng.below(u64::from(exists.saturating_sub(count))) as u32
    };
    match op {
        OpSpec::ImapList { status } => {
            let timer = Timer::start();
            let summary = client.run("LIST \"\" \"*\"", "LIST").await?;
            em.sample(label, &timer, Some(summary.list.len() as u64));
            if *status {
                let timer = Timer::start();
                let mut cmd = Vec::with_capacity(64);
                let selectable = summary.list.iter().filter(|entry| entry.selectable);
                for entry in selectable {
                    let name = &entry.name;
                    cmd.clear();
                    cmd.extend_from_slice(b"STATUS ");
                    quote(&mut cmd, name);
                    cmd.extend_from_slice(b" (MESSAGES UIDNEXT UNSEEN)");
                    client
                        .run_raw(&cmd, "STATUS", crate::proto::imap::Capture::None)
                        .await?;
                }
                em.sample(
                    "imap.status_all",
                    &timer,
                    Some(summary.list.iter().filter(|e| e.selectable).count() as u64),
                );
            }
        }
        OpSpec::ImapSelect {
            folder,
            qresync_changes,
        } => {
            if *qresync_changes > 0 {
                if !client.caps.qresync {
                    return Err(Error::config("server lacks QRESYNC"));
                }
                let probe = select(client, folder).await?;
                let (Some(validity), Some(modseq)) = (probe.uidvalidity, probe.highestmodseq)
                else {
                    return Err(Error::Protocol(
                        "SELECT without UIDVALIDITY/HIGHESTMODSEQ".into(),
                    ));
                };
                let count = (*qresync_changes).min(exists.max(1));
                let start = pick_start(&mut rng, count);
                let sign = if toggle { '-' } else { '+' };
                client
                    .run(
                        &format!(
                            "STORE {} {sign}FLAGS.SILENT (\\Flagged)",
                            seq_range(start, count)
                        ),
                        "STORE",
                    )
                    .await?;
                client.run("UNSELECT", "UNSELECT").await?;
                let mut cmd = String::with_capacity(96);
                cmd.push_str("SELECT ");
                let mut quoted = Vec::new();
                quote(&mut quoted, &client.folder_name(folder));
                cmd.push_str(&String::from_utf8_lossy(&quoted));
                let _ = write!(cmd, " (QRESYNC ({validity} {modseq}))");
                let timer = Timer::start();
                let summary = client.run(&cmd, "SELECT").await?;
                em.sample(
                    label,
                    &timer,
                    Some(u64::from(summary.fetches + summary.vanished)),
                );
            } else {
                client.run("UNSELECT", "UNSELECT").await?;
                let timer = Timer::start();
                let summary = select(client, folder).await?;
                em.sample(label, &timer, summary.exists.map(u64::from));
            }
        }
        OpSpec::ImapFetch {
            fetch,
            count,
            bucket,
            ..
        } => {
            let command = match fetch {
                FetchKind::FlagsAll => "FETCH 1:* (UID FLAGS)".to_string(),
                FetchKind::EnvelopeLast => {
                    let count = if *count == 0 { 50 } else { *count };
                    format!(
                        "FETCH {}:* (UID ENVELOPE BODYSTRUCTURE)",
                        exists.saturating_sub(count).max(1)
                    )
                }
                FetchKind::BodyBucket => {
                    let index = match bucket {
                        Some(SizeSpec::K64) => 2,
                        Some(SizeSpec::M1) => 3,
                        _ => 1,
                    };
                    format!("FETCH {index} (UID BODY.PEEK[])")
                }
                FetchKind::BodyRandom => {
                    format!("FETCH {} (UID BODY.PEEK[])", pick_start(&mut rng, 1))
                }
                FetchKind::HeaderFieldsRange => {
                    let count = if *count == 0 { 100 } else { *count }.min(exists.max(1));
                    format!(
                        "FETCH {} (UID BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID)])",
                        seq_range(pick_start(&mut rng, count), count)
                    )
                }
            };
            let timer = Timer::start();
            let summary = client.run(&command, "FETCH").await?;
            em.sample(label, &timer, Some(u64::from(summary.fetches)));
        }
        OpSpec::ImapSearch { .. } => {
            let criteria = search.unwrap_or_default();
            let timer = Timer::start();
            let summary = client
                .run(&format!("SEARCH CHARSET UTF-8 {criteria}"), "SEARCH")
                .await?;
            em.sample(label, &timer, Some(u64::from(summary.numbers)));
        }
        OpSpec::ImapSort { key, thread, .. } => {
            let command = if *thread {
                "THREAD REFERENCES UTF-8 ALL".to_string()
            } else {
                let key = match key.unwrap_or(SortKey::Date) {
                    SortKey::Date => "DATE",
                    SortKey::From => "FROM",
                    SortKey::Subject => "SUBJECT",
                    SortKey::Arrival => "ARRIVAL",
                };
                format!("SORT ({key}) UTF-8 ALL")
            };
            let timer = Timer::start();
            let summary = client
                .run(&command, if *thread { "THREAD" } else { "SORT" })
                .await?;
            em.sample(label, &timer, Some(u64::from(summary.numbers)));
        }
        OpSpec::ImapStore { flag, range, .. } => {
            let count = range.resolve(exists);
            if count == 0 {
                return Err(Error::config("mailbox is empty"));
            }
            let set = match range {
                ImapRange::All => "1:*".to_string(),
                _ => seq_range(pick_start(&mut rng, count), count),
            };
            client
                .run(&format!("STORE {set} -FLAGS.SILENT ({flag})"), "STORE")
                .await?;
            let timer = Timer::start();
            let summary = client
                .run(&format!("STORE {set} +FLAGS ({flag})"), "STORE")
                .await?;
            em.sample(label, &timer, Some(u64::from(summary.fetches)));
        }
        OpSpec::ImapCopy {
            mode,
            range,
            destination,
            folder,
        } => {
            let count = range.resolve(exists);
            if count == 0 {
                return Err(Error::config("mailbox is empty"));
            }
            let set = seq_range(pick_start(&mut rng, count), count);
            let mut dest = Vec::with_capacity(destination.len() + 2);
            quote(&mut dest, &client.folder_name(destination));
            let dest = String::from_utf8_lossy(&dest).into_owned();
            match mode {
                CopyMode::Copy => {
                    let timer = Timer::start();
                    client.run(&format!("COPY {set} {dest}"), "COPY").await?;
                    em.sample(label, &timer, Some(u64::from(count)));
                    client.run("UNSELECT", "UNSELECT").await?;
                    client.run(&format!("DELETE {dest}"), "DELETE").await?;
                    create_folder(client, destination).await?;
                    let summary = select(client, folder).await?;
                    session.exists = summary.exists.unwrap_or(0);
                }
                CopyMode::Move => {
                    let timer = Timer::start();
                    client.run(&format!("MOVE {set} {dest}"), "MOVE").await?;
                    em.sample(label, &timer, Some(u64::from(count)));
                    select(client, destination).await?;
                    let mut source = Vec::with_capacity(folder.len() + 2);
                    quote(&mut source, &client.folder_name(folder));
                    client
                        .run(
                            &format!("MOVE 1:* {}", String::from_utf8_lossy(&source)),
                            "MOVE",
                        )
                        .await?;
                    let summary = select(client, folder).await?;
                    session.exists = summary.exists.unwrap_or(0);
                }
            }
        }
        OpSpec::ImapExpunge { range, uid, folder } => {
            let count = range.resolve(exists);
            if count == 0 {
                return Err(Error::config("mailbox is empty"));
            }
            let max_uid = client
                .run("FETCH * (UID)", "FETCH")
                .await?
                .max_uid
                .ok_or_else(|| Error::Protocol("FETCH * returned no UID".into()))?;
            let templates = ctx
                .templates
                .as_ref()
                .ok_or_else(|| Error::config("missing templates"))?;
            let mut remaining = count;
            let mut batch = Vec::with_capacity(EXPUNGE_BATCH.min(count as usize));
            while remaining > 0 {
                batch.clear();
                for _ in 0..remaining.min(EXPUNGE_BATCH as u32) {
                    let id = ctx.next_id();
                    let message_id = format!("x{:x}.{id}@loadgen.{}", ctx.nonce, ctx.target.domain);
                    let mut message = Vec::new();
                    templates.write(
                        &mut rng,
                        &super::Headers {
                            from_name: "Load Generator",
                            from: "loadgen@example.com",
                            to: "user@example.org",
                            subject: "Expunge candidate",
                            message_id: &message_id,
                            date: UnixTime(DATASET_END),
                            probe: None,
                        },
                        &mut message,
                    );
                    batch.push(("\\Seen".to_string(), None, message));
                }
                remaining -= batch.len() as u32;
                client.append_pipelined(folder, &batch).await?;
            }
            client
                .run(
                    &format!("UID STORE {}:* +FLAGS.SILENT (\\Deleted)", max_uid + 1),
                    "STORE",
                )
                .await?;
            let timer = Timer::start();
            let summary = if *uid {
                client
                    .run(&format!("UID EXPUNGE {}:*", max_uid + 1), "EXPUNGE")
                    .await?
            } else {
                client.run("EXPUNGE", "EXPUNGE").await?
            };
            em.sample(
                label,
                &timer,
                Some(u64::from(summary.expunged + summary.vanished)),
            );
        }
        OpSpec::ImapAppend { folder, .. } => {
            let timer = Timer::start();
            client.append(folder, "\\Seen", None, buf).await?;
            em.sample(label, &timer, Some(buf.len() as u64));
        }
        OpSpec::Smtp { .. } | OpSpec::ImapLogin | OpSpec::ImapMixed { .. } => {
            return Err(Error::config(
                "operation not handled by the IMAP session runner",
            ));
        }
    }
    Ok(())
}
