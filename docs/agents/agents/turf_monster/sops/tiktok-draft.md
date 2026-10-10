# TikTok Draft
<!-- registry: clip slug in, a notification in Alex's TikTok inbox and its code-written caption out -->

## Status: Built; step 0 says whether this server is connected

This is Turf Monster's `tiktok-draft` SOP. It is an input-output machine. The
input is **a clip's slug**, the name printed on every clip card of an alt video
(`bigxthaplug-6wa-alt-3-clip-03`). The output is **a notification in Alex's
TikTok inbox** that opens that clip's primary version in the app's editor, and
**a caption written by code**
("Cowboys 3-2 #nfl #nfltiktok #footballtiktok #dallascowboys #cowboys #fyp")
for him to paste there. TikTok does not receive the caption, and it files
nothing under Drafts.

Alex posts from his phone ([On the phone](#on-the-phone)). Nothing here
publishes.

**Until the server is connected, step 0 fails and you stop there.** Connecting
it is Alex's, once, under [Setup](#setup).

There are two doors into the same machine (`Tiktok::DraftClip`):

| Door | Alex does | Who drafts |
|---|---|---|
| **The card** | Clicks **Draft to TikTok** on the clip's card | The server, in a background job |
| **Chat** | Hands you a clip slug | You, with `bin/tiktok-draft` |

**The card needs no agent on a normal day.** You run this SOP for the chat
door, and for a card whose attempt failed.

**One press makes one draft.** The server takes a lock on the clip before it
records an attempt, so a double click, or the card and chat together, leaves
one. The second is told `a draft of <slug> is already …`.

## The split — read this before running anything

| Alex | The code | You |
|---|---|---|
| Which clip (its slug) | Which version: the clip's primary | Running the chat door's commands |
| His word to draft it | The team, by a fixed rule (below) | Reading the dry run back to him |
| Posting it, from his phone | The record, read from ESPN at draft time | Reporting a failure in TikTok's own words |
| | The hashtags and the caption | |

**You do not write the caption and you do not recall a fact.** If the drafted
line is wrong, say why; Alex edits it on his phone, where the caption is pasted
anyway. A record from memory is the worst thing this SOP can hand him.

**One clip, on his word.** Nothing is posted, but each draft lands on his
phone as a notification, and TikTok limits how many pending uploads an app may
hold. Praise for the caption
is not his word; "draft it" or the button is.

## Scope

One clip's primary version, as a draft, to the one TikTok account the hub's
keys belong to. It does not post, schedule, pick a sound, set a cover, or draft
the stitched full video. It does not post to X (`post-to-x`). It holds no
release lane.

## Entry

Alex pastes the invocation with a slug:

```text
tiktok-draft bigxthaplug-6wa-alt-3-clip-03
```

The slug is on the clip's card, under the clip's name, with **Copy slug**. No
slug means the card door: look for an attempt that failed (step 4).

## Door one: chat — a clip slug

Run every command from the hub checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

### 0. Probe

```bash
bin/tiktok-draft --whoami --production
```

It refreshes the hub's TikTok token and asks TikTok whose account it is. It
must print the account Alex expects on his phone. Then:

| It says | Meaning | Action |
|---|---|---|
| `API 503: NOT_CONFIGURED …` | The server has no TikTok keys, or no account is connected; the message says which | Stop. Report it; see [Setup](#setup) |
| `API 502: TIKTOK_REFUSED …` | TikTok refused the token or the scope | Report TikTok's words to Alex. A new token is the sign-in at `/admin/tiktok/connect`, his to run; the hub stores what comes back |
| Another account | The keys belong to the wrong account | Stop. Do not draft |

### 1. Dry run

```bash
bin/tiktok-draft <clip-slug> --production --dry-run
```

It records nothing and reaches no TikTok. It prints the clip, its primary
version, the athlete and the rule that chose them, the team and where the team
came from, the record with where and when it was read, a `CHECK:` line for
each exception, and the caption with its length against TikTok's 2,200.

| It says | Meaning | What you do |
|---|---|---|
| `cannot draft: Clip N has no generated version yet` | No MP4 was uploaded back for this clip | Tell Alex; the clip needs a version first |
| `cannot draft: … swaps nobody` | The alt video replaces no one, so there is no athlete | Tell Alex. This clip has no caption by rule |
| `cannot draft: <athlete> has no team` | Neither the look nor the athlete carries a team | Tell Alex; he sets the team on the look or the athlete, then re-run |
| `cannot draft: <athlete>: the look "…" names team <slug>, which is not in the teams table` (or `the athlete record names team …`) | A team is named, but this server has no such team row | Not a missing team on the look. Report it: the teams must be loaded on the server ([Background](#background--not-needed-to-execute), "Where the teams come from"), or the slug is misspelled |
| `cannot draft: … only an NFL team's record can be read` | The team is in another league | Tell Alex; this machine captions NFL teams only |
| `cannot draft: could not read ESPN …` | The record could not be read | Wait and re-run. Never supply a record |
| `CHECK: … has no slogan hashtag on file` | The team table has no slogan tag | The caption went out without one. Say so |
| `CHECK: ESPN shows no finished game …` | Preseason, or week one | The record is still the one ESPN reports. Say so |

### 2. Show Alex, and wait for his word

The clip and its version, the athlete and team with the rule that chose them,
the record and where it was read, any `CHECK:` line in plain words, and the
caption exactly as printed.

### 3. Draft

Creating a draft needs an **admin session**: the hub refuses the shared token
and a builder's session on this one request. Steps 0, 1 and 4 need none. Get
one first ([The admin session](#the-admin-session)), then, in the same session:

```bash
bin/tiktok-draft <clip-slug> --production --yes
```

`--yes` is his word, not yours to add early, and it is required on every hub
that is not this machine, `--api <url>` included. It records an attempt, the
server uploads the version, and the command waits up to 150 seconds for TikTok.
It ends on one of:

| It prints | Meaning | Action |
|---|---|---|
| `attempt N: Version V · Sent to your TikTok inbox · …` | TikTok sent the notification to his inbox | Give Alex the three `next:` lines it prints and the caption ([On the phone](#on-the-phone)) |
| `still processing after 150s` | TikTok has the bytes and is still working | Run step 4 in a minute |
| `the upload reached TikTok but its status is unknown` | Every byte was sent; the status read broke | Tell Alex to look in his TikTok inbox on the phone. Run step 4. **Do not draft again** until he has looked |
| `attempt N failed: …` | TikTok refused, or the upload broke before it finished | Report TikTok's words. A retry is a new attempt, on his word |
| `a draft of <slug> is already …` | An attempt is in flight | Run step 4. Do not draft twice |
| `This session holds no admin login for this hub and AGENT_ADMIN_SESSION_TOKEN is not set` | No admin session is held | [The admin session](#the-admin-session) |
| `API 403: SESSION_FORBIDDEN …` | The token is not an admin session's | [The admin session](#the-admin-session) |
| `API 401: SESSION_ENDED …` | The admin session expired or was revoked | Grant a fresh one |

**TikTok takes no caption with a draft.** Its inbox upload accepts the file
alone, so the caption does not travel, and the editor opens with the TikTok
app's own hashtag prefilled. Give Alex the caption in chat; the clip's card
also shows it with **Copy caption**. Never tell him the caption was sent.

### On the phone

What Alex does after `Sent to your TikTok inbox`. Give him these three steps
every time; the card and the command print the same lines.

1. **Open the notification.** The TikTok app on the phone, then **Inbox**, then
   **System notifications**, then tap "Your content from McRitchie Studio is
   ready". It opens the editor. The draft is not under Drafts until he saves it
   there. The TikTok website shows the notification but, as far as we know,
   cannot open the editor.
2. **Paste the caption**, replacing the hashtag TikTok prefilled.
3. **Turn on the AI-generated label**, under **Content disclosure and ads**,
   before posting. These clips are AI video using a real athlete's likeness.

Then he posts, or saves it to Drafts.

### 4. Status, and a card whose attempt failed

```bash
bin/tiktok-draft <clip-slug> --production --status
```

It lists every attempt for the clip and re-reads TikTok for one whose bytes
TikTok holds: still processing, or uploaded with its status unknown. A failed
attempt carries TikTok's reason on the row and on the card. Fix what TikTok
named, then draft again on Alex's word; every attempt is kept.

An attempt reads **Failed** only when TikTok said so or the upload broke before
the last byte. Once the upload finished, nothing on our side fails it: it reads
**Uploaded, status unknown** until a status read settles it, and it blocks a
new draft of that clip for 15 minutes.

### The admin session

An admin session belongs to an admin soul (Xan or Steffon) and lasts 8 hours.
The board grants it. Ask, from the session that will draft:

```bash
bin/agent-activity heartbeat xan          # or steffon; prints a login-… slug
```

Alex answers the row with that slug on the board's tasks page, inside ten
minutes, one of two ways:

- **The one-time code** on the row. He gives it to you, and you post it:
  `bin/agent-activity heartbeat xan --code <code>`.
- **The Approve tap** on the row. Then run `bin/agent-activity heartbeat xan`
  again to collect.

The login is kept for this harness session, owner-only, and is never printed.
`bin/tiktok-draft` presents it to the board that granted it, and to no other hub.
`bin/agent-activity heartbeat --clear` ends it.

**When the board cannot grant** (it is down, or the draft goes to a local or
desk hub, which has no board request to answer), a shell on that hub is the
grant. It prints the token on stdout and nothing else, so take it straight into
the shell's environment, where the command reads it:

```bash
# a local or desk hub
export AGENT_ADMIN_SESSION_TOKEN="$(bin/rails agent_sessions:grant_admin)"

# production, only when the board cannot grant (the deployer's Heroku access is the grant)
export AGENT_ADMIN_SESSION_TOKEN="$(heroku run --no-tty -a mcritchie-studio -- bin/rails agent_sessions:grant_admin 2>/dev/null)"
```

`SOUL=steffon` names the other admin soul; `HOURS=1` shortens the session.
Never print the token, paste it into chat, or write it to a file: it opens
every admin-tier endpoint until it ends. If the board does not grant you a
login and you hold no shell on the hub, you hold no admin lane: stop and say
so, and Alex uses the card.

## Door two: the card

`/music_videos/<source>/alt_videos/<n>`, on the clip's card, under its
versions: **Draft to TikTok**. It is off, with the reason beside it, when the
clip has no generated version or the server is not connected to TikTok. After a click
the card shows the attempt: its state, the version sent, the caption with
**Copy caption** and a line saying TikTok did not receive it, the reminder to
turn on the AI-generated label, the rule that chose the team, TikTok's publish
id, and any error. An attempt that reads **Sent to your TikTok inbox** carries
the next step: the phone app, Inbox, System notifications, tap the
notification. The button turns itself off as it submits. **Check TikTok** re-reads the
status of an attempt still processing, or uploaded with its status unknown.
The card is open to a signed-in admin only, and needs no agent session.

## What good looks like

- The notification on Alex's phone opens the clip's primary version, and he asked for it.
- He was told the caption did not travel, and to turn on the AI-generated label.
- Every number in the caption was read in this run, and he was shown where from.
- No `CHECK:` line went by without his seeing it.
- Every attempt, failed or not, is on the clip's card.

## Handoff

One row per clip: the slug, the attempt number and its state, the caption. Then
anything held back and why. The state comes from the command's own line or the
card, never from memory.

## Setup

Once per TikTok account, and again when the refresh token dies. Every step is
Alex's to authorize; the sign-in (step 4) is his to do, in his browser.

The hub connects through a **sandbox** TikTok app. The production Turf Monster
app was refused ("not approved for personal or company internal use"), and a
sandbox app needs no review. It drafts only to the accounts listed as its
target users. What that means, and what leaving the sandbox would take, is in
[Sandbox and production](#sandbox-and-production).

**The standing page is `https://mcritchie.studio/admin/tiktok`** (Admin links,
Ops, "TikTok connection"). It says whether an account is connected and from
where, the account, the scope TikTok granted, who connected it and when, the
day the refresh token expires, whether the stored connection can still be
read, and whether the fallback env pair, the app's keys and the encryption keys
are set, by name. It carries **Sign in** (or **Sign in again**) and
**Disconnect TikTok**. It shows no token and no env value.

1. **The sandbox app**, at developers.tiktok.com:
   - Products: **Login Kit** and **Content Posting API**. Direct Post stays off.
   - Scopes: `user.info.basic` and `video.upload`.
   - Login Kit redirect URI: `https://mcritchie.studio/admin/tiktok/callback`, exactly.
   - Sandbox settings, Target Users: the account the drafts land in.
2. **File the app's keys.** The sandbox's client key and client secret go in
   the 1Password item `tiktok.studio.agents` (vault `studio-agents`), fields
   `client-key` and `client-secret`, and onto the production app through
   [`credential-filing`](../../steffon/sops/credential-filing.md). Never onto QA.
3. **The encryption keys, before any sign-in.** The hub stores the refresh
   token encrypted, so the production app must hold
   `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`,
   `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` and
   `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`. Production and QA each
   hold all three, a different set per app, filed as `active-record-encryption.studio.applications` and
   `active-record-encryption.studio-qa.applications` (vault
   `studio-applications`). So this step is a check: confirm the three names
   are present on the app, by name and never by printing a value. For each
   name, `heroku config --json --app mcritchie-studio | jq '(.ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY // "") != ""'`
   answers `true` only when the name is present and non-empty. When one is
   missing, which case it is decides the fix
   ([`credentials.md`](../../../modules/credentials.md#fact-encryption-keys)):
   a restored app that carries an existing database gets its filed set back
   from its own item, never a new one; a fresh app with an empty database gets
   its own new set, filed under its own new item; never file over an existing
   item. Either is Steffon's
   [`credential-filing`](../../steffon/sops/credential-filing.md), on Alex's
   word; never invent keys in a session, and never copy production's keys to
   QA or the reverse. On an app without them, step 4 refuses before it asks
   TikTok for anything.
4. **Sign in.** Press **Sign in with TikTok** on
   `https://mcritchie.studio/admin/tiktok`, as an admin, signed in to TikTok as
   the target user; the hub stores the connection. The page that comes back
   says it is connected and saved, and names the account, the scope TikTok
   granted and the day the refresh token expires; the standing page says the
   same from then on. Neither shows a token: there is nothing to copy and
   nothing to file.
5. **Probe.** Step 0 above. It is the first call that proves any of this.
6. **Retire the hand-filed pair, once, after the first stored sign-in probes
   clean.** Remove `TIKTOK_REFRESH_TOKEN` and `TIKTOK_OPEN_ID` from the
   production app's config and blank the `refresh-token` and `open-id` fields
   on `tiktok.studio.agents`. Left in place, the pair is a second live credential, and the
   server drafts from it whenever no connection is stored. Then run the probe
   again.

**To disconnect**, open `https://mcritchie.studio/admin/tiktok` and press
**Disconnect TikTok** (it asks first). It deletes the stored connection, comes
back to that page, and says whether the env pair is still set; if it is,
drafting carries on from the pair until step 6 is done. The server's log keeps
one line naming the admin and the time (`[tiktok] disconnect by=<slug>
at=<UTC> ...`); no table records it.

Sign in again, the same way, when the probe reports a refused token or the
expiry day nears: the same account's connection is updated in place.

When step 4 does not connect, the page says why:

| It says | Fix |
|---|---|
| `TikTok keys are not set on this server` | Step 2 |
| `This server cannot store a TikTok connection: its encryption keys are not set` | Step 3 |
| `The TikTok app lacks a permission this sign-in asked for` | Step 1: the products and the two scopes |
| `This callback address is not registered on the TikTok app` | Step 1: the redirect URI, exactly |
| `TikTok does not accept this client key` | Step 2: the key and secret are a mismatched pair, or a production app's |
| `The signed-in TikTok account is not a target user of the sandbox app` | Step 1: Target Users, or sign in as the listed account |
| `The sign-in was declined on TikTok` | Step 4 again |

**A stored connection that cannot be read.** If the encryption keys are lost or
changed after a sign-in, the stored refresh token can no longer be decrypted.
The server then counts as not connected and says "the stored TikTok connection
cannot be read; sign in again"; it does not fall back to the env pair. Step 4
again replaces the row.

**The sign-in asks for drafts only.** `user.info.basic` and `video.upload` are
all this SOP needs. Direct post (`video.publish`) is not part of it; why, and
how it is opted into, is in the Background.

## Sandbox and production

What is known about the TikTok app the hub connects through. Each claim says
whether it was measured. Check an unmeasured one against TikTok's published
requirements before acting on it.

**Measured, 2026-10-08:**

- TikTok's reviewer refused the first production app with "App will not be
  approved for personal or company internal use".
- The live app is a **sandbox** app, "McRitchie Studio", in the
  `alex@turfmonster.media` developer account. Its target user is
  `turfmonstershow`.
- A sandbox draft reached that account's inbox, and the app's editor offered
  "Everyone can view this post".

**Not measured** (the orchestrator's working knowledge on 2026-10-09, read
from no TikTok page in that session):

- A sandbox app drafts only to target users added by hand, about ten at most.
- A production app needs TikTok's review.
- Direct Post has its own audit and its own required screens.
- Review commonly takes one to two weeks.

**The decision as it stands.** Stay in the sandbox while Turf Monster is the
only account. Graduating to a production app needs a customer-facing product:
a connection per customer, a public page for the service, a privacy policy and
terms that name TikTok data, a demo video recorded against the live site, and
the narrowest scopes (`user.info.basic` and `video.upload`). No date is set
and nothing is committed.

## Background — not needed to execute

**Where the connection lives.** The sign-in's callback stores one
`TiktokConnection` row per TikTok account: the open id, the refresh token
(encrypted at rest, Active Record Encryption), the granted scope, who connected
it, and when the refresh token expires. Drafting uses the most recently
connected account. When TikTok answers a token refresh with a new refresh
token, the hub saves it over the stored one. `TIKTOK_REFRESH_TOKEN` and
`TIKTOK_OPEN_ID` are a fallback only: `Tiktok::OAuthClient` reads the env pair
when no connection is stored, and never writes to it. A stored connection that
cannot be read is not "no connection": the pair does not stand in for it. The client key and
secret stay in the environment.

**The team rule.** The caption is about the team of the clip's lead swapped
athlete, read from the alt video's swap snapshot (never the cast card as it
stands now). The athlete, first match wins: the source chunk's labelled target
when the snapshot swaps them; else the first lead among the swapped people on
screen in the window, in cast order, so two leads tie to the lower letter; else
the first swapped person on screen; else, for a window that swaps nobody, the
alt video's first swap. The team of that athlete, first match wins: the team on
the look they wear in the clip; else the athlete's current team. Past teams are
never read, so a traded athlete never yields two. `Tiktok::ClipTeam` holds the
rule and its tests.

**A team that is named but not on file.** A look or an athlete names its team
by slug. When no team row carries that slug, the draft is refused in those
words, naming the slug, and the rule does not fall through to the next source.
On 2026-10-08 production's teams table was empty: a look that said
`dallas-cowboys` read as "has no team". A look can no longer be saved, or have
its team changed, to a slug with no team row; a look that already carries one
still saves for other edits.

**Where the teams come from.** The hub's NFL teams are written by
`db/seeds/10_teams_nfl.rb`, and their metadata by `rake teams:backfill_metadata`.
No migration and no deploy step loads them: a server whose teams table is empty
needs both run, on Alex's word.

**What the first real draft measured** (production, 2026-10-08, the sandbox
app). TikTok's status read `SEND_TO_USER_INBOX` and the notification reached
the phone's inbox within a few minutes. Nothing appeared under Drafts. The
editor showed "Everyone can view this post", so a sandbox draft is not
private-only: do not tell Alex it is. No caption arrived; the app's own hashtag
was prefilled.

**The recipe.** The mascot and the record, then the tags, lower case and never
repeated: `#nfl`, `#nfltiktok`, `#footballtiktok`, the team's slogan tag from
the team table, the mascot, `#fyp`. Six at most. The record and the tag
spelling are the same code `post-to-x` uses (`Espn::TeamRecord`,
`X::PostDraft.tag`); the tag set is TikTok's own, a constant in
`Tiktok::ClipCaption`, changed by a reviewed diff. Unlike `post-to-x`, a clip
is not a "this team won" post, so a loss is no reason to stop.

**The upload.** `Tiktok::InboxUpload` sends the file itself (`FILE_UPLOAD`),
read from R2 in 10 MB chunks by the server. TikTok's other source,
`PULL_FROM_URL`, fetches only from a domain verified on the developer app, and
the R2 host is not one. Chunk rules, limits and the status words are in
`mcritchie-studio/docs/topics/content-pipeline.md`, "TikTok drafts from a clip"
(named rather than linked: the docs route serves from `docs/agents` only).

**The record of an attempt.** `tiktok_drafts`: the clip's slug, the version
number and its object, the caption, the facts it rests on, TikTok's
`publish_id` and status, and the error. The job is never retried, because a
retried upload is a second notification on the phone; a retry is a new attempt.

**Why a draft cannot double.** Three guards, each against a different way to
get two: the clip's row lock around the record (`Tiktok::DraftClip#record!`),
against two requests at once; the job's claim of the `queued` row and its
`discard_on`, against a job run twice; and the `unknown` state, against a
finished upload that looked failed and was drafted again.

**Why the API door needs an admin session.** `--yes` is checked by the command,
so anything holding a board token could call the endpoint without it. The
server now holds the line (`Api::AgentSessionGate#require_admin_session_only!`).
The grant here is the board's: the one-time code or the Approve tap, section 3 of
`mcritchie-studio/docs/agents/system/agent-sessions-design.md`. The hub-shell
grant is the fallback for when the board cannot grant.

**Drafts only, and the direct-post opt-in.** TikTok refuses the whole sign-in
with the error `scope` when the app lacks any one scope asked for, and a
sandbox app without Direct Post has no `video.publish`; the hub asked for it
until 2026-10-08 and was refused. The sign-in now asks for
`Tiktok::OAuthClient::DEFAULT_SCOPES`. Setting `TIKTOK_SCOPES` on the server
(comma-separated, from `user.info.basic`, `video.upload`, `video.publish`, and
never without the first two) widens the next sign-in; an unknown name stops
`/admin/tiktok/connect` with a message naming it. The stored
connection records the scope the sign-in was granted, as a record; what a call
may do is read from TikTok: every token refresh returns it, and the Starter Post direct-post button
(`Tiktok::PostMedia`) is refused with "this TikTok connection was authorized
for drafts only" unless that answer holds `video.publish`.

**A local demo.** A hub started with `TIKTOK_DRAFT_STAND_IN=1` answers for
TikTok and the bucket itself and marks every attempt "stand-in". Its
`/admin/tiktok/connect` skips TikTok and stores a connection named
`stand-in-account`. It never runs
in production.

**AI-generated clips of real players.** TikTok has a policy on labelling
synthetic media. The label is a switch in the app, under "Content disclosure
and ads"; no API call here can set it, so it is step 3 of
[On the phone](#on-the-phone), and the card says it on every attempt.
