# TikTok Draft
<!-- registry: clip slug in, a private draft in Alex's TikTok inbox and its code-written caption out -->

## Status: Built, waiting on TikTok keys

This is Turf Monster's `tiktok-draft` SOP. It is an input-output machine. The
input is **a clip's slug**, the name printed on every clip card of an alt video
(`bigxthaplug-6wa-alt-3-clip-03`). The output is **a draft in Alex's TikTok
inbox**, holding that clip's primary version, and **a caption written by code**
("Cowboys 3-2 #nfl #nfltiktok #footballtiktok #dallascowboys #cowboys #fyp")
for him to paste when he posts.

Alex posts from his phone. Nothing here publishes: a draft is private until he
does.

**Until the keys are filed, step 0 fails and you stop there.** What is missing,
and who supplies it, is under [What blocks it today](#what-blocks-it-today).

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

**One clip, on his word.** A draft is private, but it lands on his phone and
TikTok limits how many pending drafts an app may hold. Praise for the caption
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
| `API 503: NOT_CONFIGURED …` | The server has no TikTok keys | Stop. Report it; see [What blocks it today](#what-blocks-it-today) |
| `API 502: TIKTOK_REFUSED …` | TikTok refused the token or the scope | Report TikTok's words to Alex. A new token is the handshake at `/admin/tiktok/connect`, his to run |
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
one first ([The admin session](#the-admin-session)), then, in the same shell:

```bash
bin/tiktok-draft <clip-slug> --production --yes
```

`--yes` is his word, not yours to add early, and it is required on every hub
that is not this machine, `--api <url>` included. It records an attempt, the
server uploads the version, and the command waits up to 150 seconds for TikTok.
It ends on one of:

| It prints | Meaning | Action |
|---|---|---|
| `attempt N: Version V · In your TikTok drafts · …` | TikTok says the draft is in his inbox | Tell Alex to open TikTok's inbox, and give him the caption |
| `still processing after 150s` | TikTok has the bytes and is still working | Run step 4 in a minute |
| `the upload reached TikTok but its status is unknown` | Every byte was sent; the status read broke | Tell Alex to look in his TikTok drafts. Run step 4. **Do not draft again** until he has looked |
| `attempt N failed: …` | TikTok refused, or the upload broke before it finished | Report TikTok's words. A retry is a new attempt, on his word |
| `a draft of <slug> is already …` | An attempt is in flight | Run step 4. Do not draft twice |
| `This session holds no admin login for this hub and AGENT_ADMIN_SESSION_TOKEN is not set` | No admin session is held | [The admin session](#the-admin-session) |
| `API 403: SESSION_FORBIDDEN …` | The token is not an admin session's | [The admin session](#the-admin-session) |
| `API 401: SESSION_ENDED …` | The admin session expired or was revoked | Grant a fresh one |

**TikTok takes no caption with a draft.** Its inbox upload accepts the file
alone, so the caption does not travel. Give Alex the caption in chat; the
clip's card also shows it with **Copy caption**.

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
clip has no generated version or the server has no TikTok keys. After a click
the card shows the attempt: its state, the version sent, the caption with
**Copy caption**, the rule that chose the team, TikTok's publish id, and any
error. The button turns itself off as it submits. **Check TikTok** re-reads the
status of an attempt still processing, or uploaded with its status unknown.
The card is open to a signed-in admin only, and needs no agent session.

## What good looks like

- The draft on Alex's phone is the clip's primary version, and he asked for it.
- Every number in the caption was read in this run, and he was shown where from.
- No `CHECK:` line went by without his seeing it.
- Every attempt, failed or not, is on the clip's card.

## Handoff

One row per clip: the slug, the attempt number and its state, the caption. Then
anything held back and why. The state comes from the command's own line or the
card, never from memory.

## What blocks it today

Measured 2026-10-07: `TIKTOK_CLIENT_KEY`, `TIKTOK_CLIENT_SECRET`,
`TIKTOK_REFRESH_TOKEN` and `TIKTOK_OPEN_ID` are set on no Heroku app and in no
local env file, and the 1Password item `tiktok.studio.agents` (vault
`studio-agents`) is filed empty on purpose, with the operator's note of
2026-09-24 that TikTok is posted by hand. A draft is still posted by hand from
the phone, so this SOP does not undo that decision, but filling the item is
Alex's call: it grants the hub the ability to upload to his account.

In order, each Alex's to authorize:

1. **The developer app.** The TikTok app was submitted for review on
   2026-05-04. Whether it is approved, and whether the Content Posting API's
   upload scope (`video.upload`) is granted, could not be measured without the
   keys. An app still in sandbox can draft only to accounts added as its test
   users.
2. **The handshake.** `/admin/tiktok/connect` on production, signed in to the
   TikTok account the drafts should land in. It displays the refresh token and
   the open id once.
3. **Filing.** The four values go into `tiktok.studio.agents` and onto the
   production app through `credential-filing`. Never onto QA.
4. **The probe.** Step 0 above. It is the first call that proves any of this.

## Background — not needed to execute

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
retried upload is a second draft on the phone; a retry is a new attempt.

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

**A local demo.** A hub started with `TIKTOK_DRAFT_STAND_IN=1` answers for
TikTok and the bucket itself and marks every attempt "stand-in". It never runs
in production.

**AI-generated clips of real players.** TikTok has a policy on labelling
synthetic media, and its app offers the label when a draft is posted. Whether
these posts carry it is Alex's decision on the phone; nothing in this SOP sets it.
