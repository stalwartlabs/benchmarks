use std::fmt::Write;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use tokio::sync::oneshot;

use super::{Ctx, Emitter, Headers, WorkerState};
use crate::corpus::{UnixTime, phrase};
use crate::dataset::AccountId;
use crate::error::{Error, Result};
use crate::proto::smtp::{Security, SmtpClient};
use crate::scenario::{OpSpec, SmtpPort, SmtpProbe};
use crate::stats::{Phase, PhaseTimes, Timer, micros};

pub async fn execute(
    ctx: &Ctx,
    ws: &mut WorkerState,
    em: Emitter<'_>,
    mut timer: Timer,
) -> Result<()> {
    let OpSpec::Smtp {
        port,
        recipients,
        messages_per_connection,
        relay,
        probe,
        ..
    } = &ctx.cell.op
    else {
        return Err(Error::config("not an SMTP op"));
    };
    let templates = ctx
        .templates
        .as_ref()
        .ok_or_else(|| Error::config("missing templates"))?;
    let (addr, security, auth) = match port {
        SmtpPort::Smtp => (ctx.target.smtp, Security::Starttls, false),
        SmtpPort::Submission => (ctx.target.submission, Security::Implicit, true),
        SmtpPort::SubmissionStarttls => (ctx.target.submission_starttls, Security::Starttls, true),
    };

    let sender_account = ws.pick_user();
    let sender = if auth {
        ctx.dataset.address(sender_account)
    } else {
        let mut name = String::new();
        let mut address = String::new();
        let id = ctx.dataset.contact_sample(&mut ws.rng);
        ctx.dataset
            .write_contact(&ctx.corpus, id, &mut name, &mut address);
        address
    };
    let rcpt_accounts: Vec<AccountId> = if probe.is_imap() {
        ws.probe_users.clone()
    } else if *relay {
        Vec::new()
    } else {
        (0..*recipients)
            .map(|_| ctx.users[ws.rng.below_usize(ctx.users.len())])
            .collect()
    };
    let rcpts: Vec<String> = if *relay {
        (0..*recipients)
            .map(|_| ctx.dataset.remote_address(ws.rng.below(1_000_000)))
            .collect()
    } else {
        rcpt_accounts
            .iter()
            .map(|a| ctx.dataset.address(*a))
            .collect()
    };
    let baselines: Vec<u32> = ws.probes.iter().map(|p| p.current()).collect();
    for (probe, baseline) in ws.probes.iter().zip(&baselines) {
        probe.arm(baseline + *messages_per_connection);
    }

    let mut client =
        SmtpClient::connect(addr, &ctx.target.tls, security, &ctx.ehlo, &mut timer).await?;
    if auth {
        client
            .auth_plain(&sender, &ctx.dataset.password(sender_account), &mut timer)
            .await?;
    }

    let to_header = rcpts.join(", ");
    let mut subject = String::with_capacity(64);
    let mut message_id = String::with_capacity(64);
    let mut probe_value = String::new();
    let mut sink_waits: Vec<(u64, oneshot::Receiver<Instant>)> = Vec::new();
    let mut command_phase = PhaseTimes::default();
    let now = UnixTime(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_secs() as i64),
    );
    for _ in 0..*messages_per_connection {
        let id = ctx.next_id();
        subject.clear();
        let words = 4 + ws.rng.below(5);
        phrase(&ctx.corpus.vocab, &mut ws.rng, words, &mut subject);
        message_id.clear();
        let _ = write!(
            message_id,
            "r{:x}.{id}@loadgen.{}",
            ctx.nonce, ctx.target.domain
        );
        let probe_header = match (&ctx.sink, probe) {
            (Some(sink), SmtpProbe::Sink) => {
                sink_waits.push((id, sink.register(id)));
                probe_value.clear();
                let _ = write!(probe_value, "{} {id}", sink.addr);
                Some(probe_value.as_str())
            }
            _ => None,
        };
        templates.write(
            &mut ws.rng,
            &Headers {
                from_name: "Load Generator",
                from: &sender,
                to: &to_header,
                subject: &subject,
                message_id: &message_id,
                date: now,
                probe: probe_header,
            },
            &mut ws.buf,
        );
        let started = Instant::now();
        let result = client.send(&sender, &rcpts, &ws.buf).await;
        let elapsed = micros(started.elapsed());
        if let Err(err) = result {
            if let Some(sink) = &ctx.sink {
                for (token, _) in &sink_waits {
                    sink.forget(*token);
                }
            }
            return Err(err);
        }
        let mut phases = PhaseTimes::default();
        phases.add(Phase::Command, elapsed);
        command_phase.add(Phase::Command, elapsed);
        em.sample_us("smtp.message", elapsed, phases, None);
    }
    let mut phases = timer.phases;
    for (phase, us) in command_phase.iter() {
        phases.add(phase, us);
    }
    em.sample_us(
        "smtp",
        timer.total_us(),
        phases,
        Some(u64::from(*messages_per_connection)),
    );
    client.quit().await;

    if probe.is_imap() {
        let expected = *messages_per_connection;
        let mut latest = timer.origin;
        let mut resolution_us = 0;
        for (probe, baseline) in ws.probes.iter_mut().zip(baselines) {
            match probe.wait_for(baseline + expected, ctx.timeout).await {
                Ok(seen) => {
                    if seen.at >= latest {
                        latest = seen.at;
                        resolution_us = seen.rtt_us;
                    }
                }
                Err(err) => {
                    em.error("smtp.delivery", &err);
                    return Ok(());
                }
            }
        }
        em.sample_us(
            "smtp.delivery",
            timer.since_origin_us(latest),
            PhaseTimes::default(),
            None,
        );
        if matches!(probe, SmtpProbe::ImapPoll | SmtpProbe::ImapStatus) {
            em.sample_us("smtp.probe_rtt", resolution_us, PhaseTimes::default(), None);
        }
    }
    if let Some(sink) = &ctx.sink {
        let mut latest = timer.origin;
        for (token, rx) in sink_waits {
            match tokio::time::timeout(ctx.timeout, rx).await {
                Ok(Ok(at)) => latest = latest.max(at),
                _ => {
                    sink.forget(token);
                    em.error("smtp.relay", &Error::Timeout(ctx.timeout));
                    return Ok(());
                }
            }
        }
        em.sample_us(
            "smtp.relay",
            timer.since_origin_us(latest),
            PhaseTimes::default(),
            None,
        );
    }
    Ok(())
}
