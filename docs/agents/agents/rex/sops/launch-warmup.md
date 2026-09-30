# SOP — Launch Warm-up

**Owner:** Rex · **Runs:** whenever something new is about to meet the public: a
new app, a new domain for an existing app, or a new or imported email list. It
runs daily during the ramp, then hands over to
[`content-sprint`](content-sprint.md).

A launch is a reputation problem before it is a marketing problem. Inbox
providers, browsers and search engines have never seen the new thing, and the
first thousand sends decide what they think of it. This SOP warms it up in
gated steps. An agent can read every gate from data, so the ramp advances on
numbers, not on someone remembering to look.

Run it start to finish from this file. The worked example is the Cyvasse
relaunch (2026-09-29/30), in the table at the end.

---

## Who does each step

Every step carries one tag. The job of this SOP is to shrink the last column.

| Tag | Meaning |
|---|---|
| **AUTOMATED** | A job, rake task or API does it. Named in the step. |
| **AGENT** | An agent does it on a heartbeat: Rex for gates and offer, Steffon for DNS and infra, Mason for copy. |
| **ALEX** | Irreducible: spends money, needs a click at a registrar with no API, or an OAuth consent only he can give. |

Where a step says AGENT but names a gap, the gap is in the
[tooling appendix](#appendix--tooling-to-build). Until it is built, the agent
does the step by hand.

## Step 0 — Which launch is this?

| Launch | Run phases | Skip |
|---|---|---|
| **(a) New app** on a new domain | 0, 1, 2, 3, 4 | — |
| **(a′) New app** on a `*.mcritchie.studio` subdomain | 1, 2, 3 (link migration off), 4 | 0: it inherits an established domain, which is why it needs Phase 4's own sending subdomain |
| **(b) New domain** for an existing app | 0, 3 (link migration on), 4 | 1 and 2 if the list is already warm |
| **(c) New or imported list** | 1, 2, 3 (link migration off) | 0 and 4 unless a new domain is also involved |

Then **write the prediction** before anything sends: expected bounce rate, click
rate and arrivals for the first batch, and what result would prove it wrong.
Record it, dated, on the launch's task card and in the client dossier. An
unwritten prediction cannot be scored later.

## Phase 0 — Make the domain real before email points at it

A same-day domain in an email link reads as phishing, however clean the
authentication is (Cyvasse: SPF, DKIM and DMARC all passed and it still went to
spam). The domain earns its own history before mail carries it.

| # | Step | Tag |
|---|---|---|
| 0.1 | Buy the domain ([`domain-purchase`](../../steffon/sops/domain-purchase.md)) | **ALEX** — money |
| 0.2 | **Add the zone in Cloudflare, turn DNSSEC off at the registrar, then paste the nameservers Cloudflare assigns.** Adding the zone is a dashboard click today: the agent token has DNS write but no Zone grant. This one paste makes every later DNS step an API call. With DNSSEC on, Squarespace blocked the apex ALIAS, and a stale DS record broke resolution for hours | **ALEX** — one paste; Squarespace has no API |
| 0.3 | Write every record through the Cloudflare DNS API (token `cloudflare.studio.provision`, [credential inventory](../../../modules/credential-inventory.md)): app records, SPF, DKIM, and DMARC with an `rua` address (the ZeroBounce DMARC monitor supplies one). Verify each with `dig` from outside | **AGENT** (Steffon) |
| 0.4 | Search Console: add the property and write its TXT via the Cloudflare API; submit the sitemap | **AGENT**, after a one-time **ALEX** OAuth consent for the Search Console API |
| 0.5 | Postmaster Tools: add the domain and write its TXT via the Cloudflare API | **AGENT**, after a one-time **ALEX** click to add the domain in Postmaster's UI |
| 0.6 | Backlinks from domains that are already trusted: a page on `mcritchie.studio`, the app's social profiles, and one or two community posts | **AGENT** (Mason for the words) |
| 0.7 | Take a baseline: Google Safe Browsing lookup, DNS blocklists (for example the Spamhaus DBL), and the ZeroBounce blacklist monitor. Record it clean before the first send | **AGENT** |
| 0.8 | Keep a 301 from the established host to the new one with the path and query kept (Cyvasse: `cyvasse.mcritchie.studio` → `cyvasse.xyz`). Email links use the established host until Phase 3 moves them | **AGENT** (a task on the board) |

**Exit:** DNS resolves from outside, authentication passes, and the baseline is clean.
Domain age matters too: do not put the new domain in an email link in the first
7 days. That number is a judgement, not a measurement; the Cyvasse failure was
at day 0.

## Phase 1 — Clean the list before anyone mails it

Never mail an unverified imported list. Cyvasse's first 101 unverified sends
bounced 12.9% (13 of 101). Resend's bounce limit is 4%
(`app/services/broadcasts/analytics.rb#BOUNCE`), so one unverified batch of
2,000 would have tripped it three times over.

| # | Step | Tag |
|---|---|---|
| 1.1 | Import as contacts with one tag per list (Cyvasse: `cyvasse-legacy`), keeping last-active dates as a CSV | **AGENT** |
| 1.2 | Put the tag in `Broadcast::VERIFIED_AUDIENCES` so batches go verified-only by default (`app/models/broadcast.rb#VERIFIED_AUDIENCES`) | **AGENT** (a task on the board) |
| 1.3 | Verify the most recently active first: `bin/rails "contacts:verify[<limit>,<last_active.csv>]"`, with a `DRY_RUN=1` pass before it. It refuses to submit more than the credit balance, and it records a status on each contact | **AUTOMATED** (ZeroBounce bulk API) |
| 1.4 | Invalid, abuse, do-not-mail and spam-trap results are unsubscribed as they are recorded (`app/models/contact.rb#UNDELIVERABLE_STATUSES`). Catch-all and unknown wait | **AUTOMATED** |
| 1.5 | Credits run out → more credits, or cancel the plan when the list is done | **ALEX** — money |

**The division:** ZeroBounce ONE is $99 for 10,000 credits, about 1 cent an
address. It removed 19% of Cyvasse's first 10,000 (16% invalid, 1.5% abuse,
1.3% do-not-mail, and one spam trap). Verified batches then bounced 0.8–2.4%.
For about $200 the bounce rate fell roughly five-fold, and it is the cheapest
reputation there is.

**Expect the oldest addresses to bounce most:** Cyvasse's 2016-era addresses ran
at 2.4%. Verify and send newest-first, so the ramp's early batches are its
cleanest.

## Phase 2 — Give the first email a reason to be opened

The ramp protects reputation; the offer earns it. Mail that nobody opens,
clicks or replies to reads as unwanted to a filter, however clean the list.
Rex owns what the email asks for. Mason owns every sentence in it.

1. **An event, not an announcement.** "We're back" gives one reason to click,
   once. A fixed-time event (a weekly Cyvasse Night at a set hour; a season
   leaderboard) gives a recurring reason to email and a recurring reason to
   show up. For a multiplayer app it does a second job: it puts players in the
   same place at the same time. Cyvasse's players arrived one at a time and met
   only the computer, so there was one human-versus-human game.
2. **One main CTA, and one P.S.** The P.S. is the second most-read part of an
   email ([`channel-email`](../knowledge/channel-email.md): "Beyond the headline
   it's the most read part of the email"). Cyvasse's P.S., "we'll build your
   app", drew 34 clicks against 52 on Play Now: 34 ÷ 86 = **40% of all clicks,
   from a line nobody planned as the offer.** Give every launch email a P.S.
   cross-sell into a funnel that records a result (`/build` records
   `requested_app`, `app/models/email_event.rb#GOALS`).
3. **Make it look like a person wrote it.** No stock hero image, no "Welcome
   admin!", no urgency, and no money language. The Cyvasse sign-in email that
   went to spam had all of the first three. Mostly text, with one or two links.
4. **Send in the morning, recipient time.** Cyvasse's morning batches clicked
   far better than the midnight one. Send between 10:00 and 12:00 or 13:00 and
   15:00, recipient local time.
5. **The click has to land somewhere that pays off.** Cyvasse: 52 Play Now
   clicks, 12 arrivals, 9 plays, all as guests. There is no email-to-account
   handoff yet, so a returning player never sees their old account. A leak after
   the click is a product task for Avi's board, not a copy problem.

## Phase 3 — The ramp: batches, gated

Batches go out with
`bin/rails "broadcasts:send_batch[<slug>,<size>,<audience>]"`. Each batch takes
random unsent, subscribed contacts, verified-only for a verified audience, and
spaces the sends for Resend's rate limit (`app/models/broadcast.rb#send_batch!`).
`broadcasts:batch_status` reports sent, remaining, opened and clicked
(`app/models/broadcast.rb#batch_status`).
A personalized email (the reader's own stats in it) is staged, reviewed and
approved first, then sent with `broadcasts:execute`, which holds itself to the
same bounce and complaint limits as the table below
([`docs/email-delivery.md`](../../../../email-delivery.md#staged-sends-review-before-execute)).

| Stage | Who gets it | Links point at | Size |
|---|---|---|---|
| 1 | The engaged segment: newest verified, or opened in the last 30 days | The **established** domain | 100 |
| 2 | Engaged plus recent openers | The main CTA on the **new** domain; the rest established | 1,000 |
| 3 | A/B half of the remaining list, new domain against established | Split | 2,000 |
| 4 | Everyone | The new domain | Double each batch |
| 5 | Transactional mail (sign-in, receipts) | The new domain | All |

**Link migration applies only to launch (b), and to (a) on a new domain.** For a
list launch (c), run the sizes with every link on the established domain.

Cyvasse ran 100 → 1,000 → 2,000 and up with no link migration, so stages 2–5's link
steps are untested. The first launch to run them owes a note on whether they
held.

### The gate — read before every advance

**AGENT** (Rex, on the heartbeat), **24 hours after the batch's last send**:
complaints lag, and a gate read at hour one is a gate that always passes. Every
row must be green to advance a stage.

| Gate | Green | Where the number lives |
|---|---|---|
| Bounce rate (hard + soft ÷ sent) | < 2% | `/broadcasts/analytics?broadcast=<slug>`, the same limits the dashboard colours by |
| Complaint rate | < 0.05% (the dashboard's amber; Resend's limit is 0.08%) | `/broadcasts/analytics` |
| Unsubscribe rate | < 0.5% | `/broadcasts/analytics` |
| Gmail spam rate | < 0.1% | Postmaster Tools |
| Gmail domain reputation | Medium or better | Postmaster Tools. **No data is not a pass**: it may advance stages 1–2 on the other gates, but stage 3 onward needs a reading |
| Inbox placement | Inbox, not spam, at Gmail and Outlook | A ZeroBounce placement test (100 a month) on the exact email, run before the batch |
| Blocklists | No new listing since the baseline | ZeroBounce blacklist monitor |
| Click rate | Report it; do not gate on it | `/broadcasts/analytics`. A low click rate is Phase 2's problem, not a reason to stop |

### Rollback

- **One amber or red gate** → step back one stage and halve the batch. Rerun the
  gate on the smaller batch.
- **Red twice in a row** → stop the ramp and tell Alex, with the numbers.
- **Complaint rate at or above 0.08%, a new blocklist listing, or a spam-trap
  hit** → stop every send from that domain today. Re-verify the audience before
  resuming at stage 1.
- **Placement test lands in spam** → do not send that email. Change the email,
  not the list: images, links, then wording, in that order.

## Phase 4 — A sending subdomain of its own

`mcritchie.studio`'s reputation is shared by HubSpot and Resend. A launch that
misbehaves spends every other product's inbox. Give each mail stream its own
subdomain (`notify.` for transactional, `news.` for broadcasts) and warm it up
separately.

| # | Step | Tag |
|---|---|---|
| 4.1 | Create the sending domain in Resend and write its DKIM, SPF and return-path records through the Cloudflare API | **AGENT** (Steffon) |
| 4.2 | Start at about **50 a day to the engaged segment** and roughly double every 2–3 days while the gate stays green | **AGENT** until the scheduler exists |
| 4.3 | Any red gate → hold the size for three days, then resume doubling | **AGENT** |

**The division:** 50 × 2⁷ = 6,400 a day after seven doublings, which is 14–21
days. Plan the launch calendar around three weeks, not one.

## Reading the result

At the end of the ramp, open the prediction from Step 0 and answer in order:
what did we predict, what happened, and was it high, low or right. **Say which.**
Then name the constraint the launch exposed. Cyvasse's was the arrival handoff,
not the list. Hand it to
[`constraint-diagnosis`](constraint-diagnosis.md) and move the list to the
weekly [`content-sprint`](content-sprint.md).

---

## Worked example — Cyvasse, 2026-09-29/30

| What | Number |
|---|---|
| List | 18,745 legacy players imported, tagged `cyvasse-legacy` |
| First unverified batch | 101 sends, 13 bounced (12.9%) |
| Verification of 10,000 | 81% kept (valid, catch-all or unknown), 16% invalid, 1.5% abuse, 1.3% do-not-mail, 1 spam trap |
| Verified batches | 100 → 1,000 → 2,000, then larger, to 8,239 sends by 2026-09-30; bounce 0.8–2.4%, oldest addresses highest |
| Complaints | 0 across 8,239 sends |
| Clicks | 52 Play Now, 34 on the P.S. (40% of clicks) |
| Funnel | 52 clicks → 12 arrivals → 9 plays, all as guests; 1 human-versus-human game |
| Domain | `cyvasse.xyz` bought and made canonical the same day. A sign-in email linking it went to Gmail spam despite SPF, DKIM and DMARC passing. Fix: email links use `cyvasse.mcritchie.studio`, which 301s |
| DNS | DNSSEC on Squarespace blocked the apex ALIAS; a stale DS record broke resolution for hours |

What this SOP would have changed: Phase 1 before the first 101, Phase 0's
seven-day rule before the sign-in email, and Phase 2's event before the first
batch.

## The ALEX steps that remain

1. **Buy the domain**: money, and Squarespace has no purchase API.
2. **Add the zone, turn DNSSEC off and point the nameservers at Cloudflare**:
   one click and one paste per domain, and every later DNS record becomes an agent's API call.
3. **One-time consents**: the Search Console API OAuth, adding the domain in
   Postmaster Tools, and the Postmaster Tools API OAuth once the heartbeat reads
   it.
4. **Spend**: ZeroBounce credits and renewals, and a Resend plan when volume
   outgrows it.
5. **Stop-the-ramp escalations**: two reds in a row. He decides whether the
   launch continues.

---

## Appendix — Tooling to build

Ranked by how many manual steps each removes. Each is a task on the board and
rides the DevOps cycle.

1. **Gate heartbeat**: a job reads `Broadcasts::Analytics` plus the Postmaster Tools API 24 hours after a batch and writes green, amber or red on the broadcast.
2. **Auto-batching**: a scheduled job sends the next stage's batch in the morning window when the gate heartbeat reads green, and steps back when it reads red.
3. **Saved segments**: `engaged` (opened or clicked in the last 30 days) and `newest-verified` as audiences `send_batch` accepts.
4. **Per-batch link host** on a broadcast, so stages 1–4 of the link migration are a field, not a template edit.
5. **Placement test before each batch**: call ZeroBounce's placement test on the batch's email, if its API offers one (unverified), and block the batch on a spam result.
6. **Domain-age awareness**: record each domain's registration date and refuse a new-domain link in email before day 7.
7. **Sending-subdomain warm-up scheduler**: the 50-a-day doubling as a daily cap that grows only on a green gate.
8. **Launch-domain provisioner**: one command that writes the zone, auth records, Search Console and Postmaster TXTs, and the blocklist baseline through the Cloudflare API.
9. **Email-to-account handoff**: a click from a legacy player signs them into their old account, so arrivals stop landing as guests.
10. **`/build` lead capture**: `requested_app` is already recorded; route each P.S.-sourced request to a follow-up queue with its source broadcast.
