use super::{Ctx, Emitter, WorkerState};
use crate::error::Result;
use crate::proto::imap::ImapClient;
use crate::scenario::MixedProfile;
use crate::stats::Timer;

pub async fn execute(
    ctx: &Ctx,
    ws: &mut WorkerState,
    em: Emitter<'_>,
    mut timer: Timer,
    profile: &MixedProfile,
) -> Result<()> {
    let account = ws.pick_user();
    let mut client = ImapClient::connect_login(
        ctx.target.imap,
        &ctx.target.tls,
        &ctx.dataset.address(account),
        &ctx.dataset.password(account),
        &mut timer,
    )
    .await?;
    em.sample("mixed.login", &timer, None);
    client.setup().await?;

    let step = Timer::start();
    let exists = client
        .run("SELECT INBOX", "SELECT")
        .await?
        .exists
        .unwrap_or(0);
    em.sample("mixed.select", &step, Some(u64::from(exists)));

    if exists > 0 {
        let step = Timer::start();
        let from = exists.saturating_sub(profile.sync_window).max(1);
        let summary = client
            .run(&format!("FETCH {from}:* (UID FLAGS)"), "FETCH")
            .await?;
        em.sample("mixed.sync", &step, Some(u64::from(summary.fetches)));

        let step = Timer::start();
        let new_from = exists.saturating_sub(profile.fetch_new).max(1);
        let summary = client
            .run(
                &format!("FETCH {new_from}:* (UID FLAGS ENVELOPE BODYSTRUCTURE)"),
                "FETCH",
            )
            .await?;
        em.sample("mixed.fetch_new", &step, Some(u64::from(summary.fetches)));

        for _ in 0..profile.read_bodies {
            let seq = new_from + ws.rng.below(u64::from(exists - new_from + 1)) as u32;
            let step = Timer::start();
            client
                .run(&format!("FETCH {seq} (BODY[])"), "FETCH")
                .await?;
            em.sample("mixed.read", &step, None);
        }

        if ws.rng.chance(profile.flag_probability) {
            let seq = 1 + ws.rng.below(u64::from(exists)) as u32;
            let sign = if ws.rng.chance(0.5) { '+' } else { '-' };
            let step = Timer::start();
            client
                .run(&format!("STORE {seq} {sign}FLAGS (\\Flagged)"), "STORE")
                .await?;
            em.sample("mixed.flag", &step, None);
        }

        if ws.rng.chance(profile.search_probability) {
            let [lo, hi] = profile.search_ranks;
            let word = ctx.corpus.vocab.pick_in_ranks(&mut ws.rng, lo, hi);
            let step = Timer::start();
            let summary = client
                .run(&format!("SEARCH TEXT \"{word}\""), "SEARCH")
                .await?;
            em.sample("mixed.search", &step, Some(u64::from(summary.numbers)));
        }

        if exists > 1 && ws.rng.chance(profile.move_probability) {
            let seq = 1 + ws.rng.below(u64::from(exists)) as u32;
            let step = Timer::start();
            client
                .run(&format!("MOVE {seq} \"Archive\""), "MOVE")
                .await?;
            em.sample("mixed.move", &step, None);
        }

        if exists > 2 && ws.rng.chance(profile.delete_probability) {
            let seq = 1 + ws.rng.below(u64::from(exists - 1)) as u32;
            let step = Timer::start();
            client.run(&format!("MOVE {seq} \"Trash\""), "MOVE").await?;
            em.sample("mixed.delete", &step, None);
        }
    }

    let step = Timer::start();
    client.logout().await?;
    em.sample("mixed.logout", &step, None);
    em.sample("mixed.session", &timer, None);
    Ok(())
}
