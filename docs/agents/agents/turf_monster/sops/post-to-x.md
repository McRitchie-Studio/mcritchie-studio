# Post To X
<!-- registry: winning team + video in, drafted and approved post on @turfmonstershow out -->

## Status: Active

This is Turf Monster's `post-to-x` SOP. It is an input-output machine. The
input is **the team that won and a video**. The output is a post on
`@turfmonstershow`: "Chiefs 4-0 #nfl #nflfootball #chiefskingdom #kansascity
#chiefs", with the video attached.

The copy is written by code, not by you. `X::PostDraft` reads the team's live
record and its tags and builds the line the same way every time. Alex approves
it, and it posts.

There are two doors into the same machine:

| Door | Alex does | Who posts |
|---|---|---|
| **The board** | Picks the team and uploads the MP4 on a Video Post (X) card, looks at the preview, clicks **Post to X** | The server, in a background job |
| **Chat** | Hands you a file path and says who won | You, with `bin/x-post` |

**The board needs no agent on a normal day.** You run this SOP for the chat
door, and for the board's exceptions: a card whose draft failed, a card flagged
"check before posting", or a card stuck mid-post.

## The split — read this before running anything

| Alex | The code | You |
|---|---|---|
| The team that won | The record, read from ESPN at draft time | Running the chat door's commands |
| The video | The tags, from the team table | Judging an exception the code flagged |
| The approval: his click, or his "send it" | The copy, the length check, the upload, the link | Telling him what you found, in his words |

**You do not write the copy and you do not recall a fact.** If the drafted line
is wrong, say why and let Alex edit it; do not hand-build a different one. A
record from memory is the worst thing this SOP can publish, and a model's
memory of a season is always out of date.

**A post is public the moment it lands, and nothing here undoes it.** Approval
comes first, every time. Praise for the copy is not approval; "send it" or the
Post button is.

## Scope

Video posts to one X account. It does not render or edit video, does not reply,
quote, delete or schedule, and does not post to TikTok or Instagram. It holds
no release lane.

## Entry

**From the chip.** Alex copies `post-to-x` from the Turf Monster launcher on
`/deployments` and pastes it into a fresh session with the rest of his input:

```text
post-to-x /Users/alex/Downloads/clip.mp4 Vikings win
post-to-x /Users/alex/Downloads/clip.mp4 Bijan eating, joke about every B. Robinson eating
```

Read it as: the MP4 path, then the team or the context. That is the chat
door below. Several paths in one message are one batch. No path at all means
the board door: look for cards that need you.

Then, before anything else:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/x-post whoami
```

It must print `@turfmonstershow`. Any other handle, stop. An HTTP 401 means X
no longer accepts the keys: report it to Alex, because new keys come from the X
developer console and are refiled in `agent.turf.x` by `credential-rotation`.
A 1Password failure (the item cannot be read at all) is `credential-issues`.

## Door one: chat — a file path and a winner

### 1. Draft

```bash
bin/x-post draft <team> \
  --caption-file "${CLAUDE_SCRATCHPAD:-/tmp}/x-post/<name>/caption.txt"
```

`<team>` is the mascot (`chiefs`), the short code (`KC`) or the full name. A
city two teams share (`new york`) is refused; use the mascot.

It prints the copy, then on stderr the record with where and when it was read,
the team's most recent final, and a `CHECK:` line for each exception:

| `CHECK:` says | What it means | What you do |
|---|---|---|
| the most recent final … is a LOSS | The record has not caught up, or Alex named the wrong team | Tell Alex. Do not post until the final shows as a win or he says otherwise |
| kicked off … more than a week ago | That is last week's game | Tell Alex; the video may be for a game that has not gone final |
| has no slogan hashtag on file | The team table has no tag for this team | The copy went out without one. Say so; he can add one |

Make the directory first (`mkdir -p`), one per video, named for the video, and
write the whole path at every site: the scratchpad is shared between sibling
agents and no shell variable survives a turn.

### 2. Check

```bash
bin/x-post check <video.mp4> \
  --caption-file "${CLAUDE_SCRATCHPAD:-/tmp}/x-post/<name>/caption.txt"
```

It reads no credential and calls nothing. It prints the exact text, its weight
against X's 280, and the video's size, dimensions, frame rate and length, and
exits 1 with a `REFUSED` line for anything X would reject: over 280, over
60fps, an unreadable file, more than eight tags.

Then look at the video. Pull a few frames and confirm it is the team Alex
named; a clip posted under the wrong team's record is public before anyone
notices.

### 3. Show Alex, and wait for his word

The copy exactly as `check` printed it, the record and the final it rests on,
any `CHECK:` line in plain words, and the video's length. Several videos go in
one table.

**What he approves is that text.** If he edits it, write his version to the
caption file, re-run `check`, and show him the result.

### 4. Post

```bash
bin/x-post post <video.mp4> \
  --caption-file "${CLAUDE_SCRATCHPAD:-/tmp}/x-post/<name>/caption.txt" --yes
```

It re-runs the check, confirms the account, uploads, waits for X to process
the video, posts, and prints `posted: https://x.com/turfmonstershow/status/…`.

### 5. Record it on the board

```bash
bin/content record-post --post-url "<the link post printed>" \
  --caption-file "${CLAUDE_SCRATCHPAD:-/tmp}/x-post/<name>/caption.txt"
```

This files a card at `posted` with the link and the copy, so the board holds
one record of everything that went out. It posts nothing, and running it twice
with the same link files nothing twice.

### If `post` does not print a link

| It says | Meaning | Action |
|---|---|---|
| `X refused the post, nothing is live` | X answered no: a 4xx, or the upload failed before any post existed | Fix what X named and run `post` again |
| `X did not confirm the post and it MAY BE LIVE` | A server error, or an answer with no id | **Open the timeline first.** If the video is there, record its link with step 5 and stop |
| `an attempt … never recorded a result, so it may be LIVE` | An earlier run died mid-post | The same: timeline first. `--again` only once you have seen it is not there |
| `this video was already posted` | The ledger holds this file's sha256 | It prints the first link. Only Alex decides to post a video twice |

X's own refusals, when it gives one: a 403 with "duplicate" means that exact
text is already on the account, so look at the timeline before changing the
copy; any other 403 is the app's write permission or the account, reported to
Alex verbatim; a message about credits or billing is his to top up; a 429 is a
wait.

## Door two: the board — when a card needs you

```bash
bin/content list --workflow video_post_x --stage idea
bin/content list --workflow video_post_x --stage assembly
```

- **A card at `idea`** has a video and no copy: its draft failed, usually
  because ESPN could not be read. The card says why. Its **Draft the copy**
  button retries; if ESPN is still down, run `bin/x-post draft <team>` to see
  whether it is the feed or the team, and tell Alex.
- **A card at `script`** is ready and waiting on Alex's click. Leave it. If it
  carries a "Check before posting" line, that line is the same `CHECK:` as
  above and gets the same answer.
- **A card at `assembly` saying "Check the timeline"** is a post that started
  and never reported back. The card links the timeline and offers two answers:
  paste the link if the video is live, or say it is not there. Look, then
  tell Alex which; he clicks.
- **The Post button is off and says "the X keys are not set on this server".**
  The server posts with four keys from `agent.turf.x`. Putting them on a server
  is `credential-filing`, on Alex's word, and never on QA.

## What good looks like

- Every post matches the text Alex approved, character for character.
- Every number was read in this run, and Alex was shown where from.
- Every post has a card at `posted` carrying its link.
- No `CHECK:` line was posted through without Alex seeing it.

## Handoff

One row per video: the file or card, the link, the copy. Then anything held
back and why. The link comes from the command's `posted:` line, the card, or
`bin/x-post ledger`, never from memory.

---

## Background — not needed to execute

**The recipe.** Hook: the mascot and the record. Tags, in order and lower
case: `#nfl`, `#nflfootball`, the team's slogan tag from the team table, the
city, the mascot, and `#tnf`, `#snf` or `#mnf` when the kickoff was in that
window (Eastern time). A tag is never repeated. Alex set this shape on
2026-10-04, and five of that night's posts match what the recipe produces
today.

**The board door.** `/contents/new` → **Video Post (X)** → the winner and the
MP4 (up to 100 MB). `Content::AttachVideo` stores the file, `Content::DraftXCopy`
drafts the copy, and the card shows it as X will draw it. **Post to X** takes
the card to `assembly` and queues `ContentPostVideoToXJob`; the job posts,
moves the card to `posted` with its link, and reads the post back from X to
confirm the video attached. The job is never retried, and it will not post
unless it is the first run to claim the card, because a queue can hand a dead
worker's job to another.

**Two ledgers, on purpose.** `bin/x-post` keeps a local file keyed by the
video's sha256 so the chat door cannot post one file twice. The board keeps the
card. Step 5 is what joins them.

`bin/x-post` and the card both use `X::PostMedia`, described in
`mcritchie-studio/docs/topics/content-pipeline.md` (named rather than linked:
the docs route serves from `docs/agents` only). X bills the API per call; the
developer console is the authority on the price.

**AI-generated clips of real players.** X has a policy on labelling synthetic
media. Whether and how these posts are labelled is Alex's decision; nothing in
this SOP labels them.
