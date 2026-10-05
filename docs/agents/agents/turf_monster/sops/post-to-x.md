# Post To X

## Status: Active

This is Turf Monster's `post-to-x` SOP. Alex puts a finished MP4 on the content
board with a few words of context ("Panthers win"). You turn the context into
post copy ("Panthers 3-1 #nfl #nflfootball #keeppounding #carolina #panthers
#snf"), show him the batch, post each video to `@turfmonstershow` on his word,
and record the link on the card.

It is Turf Monster's because the copy is a sports read: which record, which
tags a fan base actually uses, which slot the game was in.

**It is a QUEUE DRAIN.** Cards wait on the board at `idea` under the
`video_post_x` workflow. Run it when Alex says he has added some, or names the
SOP. An empty queue is a normal end.

## The split — read this before running anything

| Alex, on the board | You | The code |
|---|---|---|
| The MP4 | The copy, built from his context | Storing the video, the claim and its lease |
| The context, in a few words | Every fact the copy adds, read from a source | Measuring the copy the way X does |
| The go for the batch | The hashtags | Uploading, posting, recording the link |

**You may add a fact. You may not recall one.** "Panthers win" becoming
"Panthers 3-1" is the job. But the 3-1 comes from a read you made in this run,
and the approval table names where each number came from. A record written
from memory is the worst thing this SOP can publish, and a model's memory of a
season is always out of date.

**A post is public the moment it lands, and this SOP has no undo.** The order
below is fixed for that reason: draft everything, show everything, then post.

## Scope

This SOP posts video to one X account. It does not render or edit video, does
not reply, quote, delete or schedule, and does not post to TikTok or Instagram.
It holds no release lane.

## Entry

```bash
cd /Users/alex/projects/mcritchie-studio
bin/content list --stage idea --workflow video_post_x --claimable
```

That is the queue. If it prints `no content`, say so and stop.

## Preconditions

**1. The credentials post as the right account.**

```bash
bin/x-post whoami
```

It must print `@turfmonstershow`. Any other handle, stop. An HTTP 401 or a
1Password failure is the `token-session` SOP. `bin/x-post` reads the
`agent.turf.x` item itself; never paste a key into a command.

**2. You have a per-soul session, exported once for the whole run.**

```bash
export CONTENT_SESSION="content-turf-monster-$$"
```

The session string is the whole proof of a claim. The reasoning is in
[`content-build`](content-build.md) § Preconditions and holds here unchanged.

## The loop

### 1. Read every card in the queue, without claiming

```bash
bin/content show <slug>
```

It prints the `context` Alex wrote and the `video` URL. **Do not claim yet.**
A claim is a 30-minute lease, and Alex's approval can take longer than that.

A card whose context does not tell you what the video is goes back to him as a
question. Do not write copy from the filename.

### 2. Read the facts the copy will carry

Every number comes from a read in this run. For a team's record:

```bash
curl -s "https://site.api.espn.com/apis/site/v2/sports/football/nfl/teams/<abbr>" \
  | jq -r '.team | "\(.displayName) \(.record.items[0].summary)"'
```

`<abbr>` is the `Short` column of `db/seeds/data/teams_hashtags.csv`, lower
case (`car`, `buf`). The read is live, so run it after the game Alex is
posting about has gone final, and check the record moved: a card that says
"Panthers win" against a record that has not gained a win means the feed is
behind, and that card waits.

If the context implies a fact you cannot read from a source (a stat line, a
streak, a quote), leave it out of the copy and say so in the batch table.

### 3. Write the copy

The shape Alex set: **the hook, then the tags, on one line.**

```
Panthers 3-1 #nfl #nflfootball #keeppounding #carolina #panthers #snf
```

- **The hook is short and carries the fact.** Team and record, or team and
  score. No sentence around it.
- **About six tags, lower case, in this order:** the league (`#nfl`,
  `#nflfootball`), the team's own slogan tag, the city, the team name, and the
  slot when there is one (`#snf`, `#mnf`, `#tnf`). Eight is the ceiling and
  the command refuses a ninth.
- **The slogan tag is read, not recalled:**

  ```bash
  grep -i "<team name>" db/seeds/data/teams_hashtags.csv
  ```

  The `Hashtag` column is the tag. Lower-case it to match the rest.
- **Every tag is about this video.** No trending tag borrowed for reach.
- **Correct Alex's spelling.** "Panters" in the context is "Panthers" in the
  post.
- **No link** unless his context has one. X bills a post with a link at
  several times a plain post, and the command says so when it sees one.

Write each card's copy to its own file, named by the card's slug, with the
whole path at every site. The scratchpad is shared between sibling agents and
no shell variable survives a turn.

```bash
mkdir -p "${CLAUDE_SCRATCHPAD:-/tmp}/x-post/<slug>"

cat > "${CLAUDE_SCRATCHPAD:-/tmp}/x-post/<slug>/caption.txt" <<'EOF'
Panthers 3-1 #nfl #nflfootball #keeppounding #carolina #panthers #snf
EOF
```

A file, because copy carries `#`, `$` and quotes, and a shell argument eats
them.

### 4. Download and check every post, before asking for anything

```bash
curl -fsS -o "${CLAUDE_SCRATCHPAD:-/tmp}/x-post/<slug>/video.mp4" "<video URL from show>"

bin/x-post check "${CLAUDE_SCRATCHPAD:-/tmp}/x-post/<slug>/video.mp4" \
  --caption-file "${CLAUDE_SCRATCHPAD:-/tmp}/x-post/<slug>/caption.txt"
```

`check` reads no credential and calls nothing. It prints the exact text, its
weight against X's 280, and the video's size, dimensions, frame rate and
length. It exits 1 with a `REFUSED` line for anything X would reject:

| Refusal | What to do |
|---|---|
| `weighs N, over X's 280` | Shorten it. Emoji weigh 2, so `String#length` lies here |
| `Nfps, over X's 60` | The file needs re-encoding at 30fps. Report it; leave it out of the batch |
| `ffprobe could not read a video stream` | The upload is not a video, or is damaged. Report it |
| `N hashtags, over the 8` | Cut tags |

### 5. Show Alex the batch, and wait for one word

One table, every card, nothing summarised:

| # | Card | Context he wrote | Copy exactly as `check` printed it | Facts added, and where each was read |
|---|---|---|---|---|

Under it, list anything refused or held back and why. Then ask for the go.

**What he approves is the copy in that table.** If any copy changes after his
yes, re-run `check` and show him that row again. An approval covers this
batch; it does not carry to the next one.

### 6. Post, one card at a time

For each approved card: claim, write the copy onto the card, post, record.

```bash
bin/content claim --agent turf-monster --stage idea --workflow video_post_x
```

The SERVER picks the card and prints its slug. **If it hands you a slug that
is not in the approved batch**, a new card arrived while Alex was reading:
`bin/content release <slug>` and leave it for the next run. Never post copy
he has not seen.

```bash
bin/content write <slug> \
  --caption-file "${CLAUDE_SCRATCHPAD:-/tmp}/x-post/<slug>/caption.txt"

bin/x-post post "${CLAUDE_SCRATCHPAD:-/tmp}/x-post/<slug>/video.mp4" \
  --caption-file "${CLAUDE_SCRATCHPAD:-/tmp}/x-post/<slug>/caption.txt" --yes
```

`post` re-runs the check, confirms the account, uploads, waits for X to
process the video, posts, and prints
`posted: https://x.com/turfmonstershow/status/…`. Processing takes from a few
seconds to a few minutes. Then put that link on the card:

```bash
bin/content posted <slug> --post-url "<the link post printed>"
```

`posted` moves the card to `posted`, shows the link on it, and releases the
claim. It takes only an `x.com` status URL and only from the claim's holder.

**`post` will not send the same file twice.** Every success goes into a ledger
keyed by the file's sha256, and a second `post` of that file refuses and
prints the first link. So if a run dies between `post` and `posted`, re-run
`post`: it refuses, hands you the link, and you finish with `posted`.
`--again` overrides the ledger, and only Alex decides to post a video twice.

A `409` on `write` or `posted` is the claim: `CLAIM_LAPSED` means the 30
minutes ran out, so claim again; `CLAIM_HELD` means another session has the
card, so leave it.

### 7. If X refuses

`post` prints X's own words and records nothing. Release the card
(`bin/content release <slug>`) so it is not stranded, and stop the batch at
the first refusal you cannot explain; five more of the same are five more
billed attempts.

| X says | Meaning | Action |
|---|---|---|
| 401 | The credentials no longer work | `token-session` |
| 403, with "duplicate" | That exact text was posted recently | Change the copy; ask Alex |
| 403, otherwise | The X app lost write permission, or the account is restricted | Report to Alex verbatim |
| A message about credits, billing or usage | The developer account has no balance | Alex tops it up; only he holds the billing |
| 429 | Rate limited | Wait for the window X names, then resume |
| `media processing failed` | X could not transcode the file | Report the file; do not retry it unchanged |

## What good looks like

- Every post matches the copy Alex approved, character for character.
- Every number in every post was read from a source in this run, and the
  batch table said which.
- Every posted card sits in `posted` with its link, and nothing is left
  claimed.
- Cards you held back are still at `idea`, with the reason in your report.

## Handoff

Report to Alex with one row per card: the card, the link, the copy. Then what
was held back and why, and the board URL. The link comes from the command's
`posted:` line or `bin/x-post ledger`, never from memory.

## A video that is not on the board

`bin/x-post check` and `post` take any local MP4, so a file Alex hands you by
path can be posted the same way with no card: write the copy file, `check`,
show him, `post`. Use it when he asks for it by name. The board is the
default because the card keeps the context, the copy and the link together.

---

## Background — not needed to execute

Alex creates the card at `/contents/new` by choosing **Video Post (X)**,
attaching the MP4 and writing the context in Description; the upload is capped
at 100 MB because it rides a web request. `Content::AttachVideo` stores the
file and records its URL on the card.

`bin/x-post` wraps `X::PostMedia`, the uploader the Starter Post X workflow
also uses, described in `mcritchie-studio/docs/topics/content-pipeline.md`
(named rather than linked: the docs route serves from `docs/agents` only). The
upload is X's v2 chunked sequence, signed with OAuth 1.0a. X switched off the
v1.1 upload host on 2025-06-09; the uploader moved to v2 on 2026-10-04.

Posting lives with a soul, and not behind a button on the card, for two
reasons: production holds no X keys, and an upload plus X's processing
outlasts the 30 seconds a web request gets.

X bills the API per call. Third-party price lists read on 2026-10-04 put a
plain post near $0.015 and a post with a link near $0.20; the developer
console is the authority, not this paragraph.
